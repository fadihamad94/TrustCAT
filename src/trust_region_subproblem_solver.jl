export phi, findinterval, bisection
using LinearAlgebra
#=
The big picture idea here is to optimize the trust region subproblem using a factorization method based
on the optimality conditions:
H d_k + g + δ d_k = 0
H + δ I ≥ 0
δ(r -  ||d_k ||) = 0

That is why we defined the below phi to solve that using bisection logic.
=#

const OPTIMIZATION_METHOD_TRS = "GALAHAD_TRS"
const OPTIMIZATION_METHOD_GLTR = "GALAHAD_GLTR"
const OPTIMIZATION_METHOD_DEFAULT = "OUR_APPROACH"

const LIBRARY_PATH_TRS = string(@__DIR__ ,"/../lib/trs.so")
const LIBRARY_PATH_GLTR = string(@__DIR__ ,"/../lib/gltr.so")

mutable struct Subproblem_Solver_Methods
    OPTIMIZATION_METHOD_TRS::String
    OPTIMIZATION_METHOD_GLTR::String
    OPTIMIZATION_METHOD_DEFAULT::String
    function Subproblem_Solver_Methods()
        return new(OPTIMIZATION_METHOD_TRS, OPTIMIZATION_METHOD_GLTR, OPTIMIZATION_METHOD_DEFAULT)
    end
end

const subproblem_solver_methods = Subproblem_Solver_Methods()

function if_mkpath(dir::String)
  if !isdir(dir)
     mkpath(dir)
  end
end

struct userdata_type_trs
	status::Cint
	factorizations::Cint
	hard_case::Cuchar
	multiplier::Cdouble
end

#Data returned by calling the GALAHAD library in case we solve trust region subproblem
#using their GLTR approach
struct userdata_type_gltr
	status::Cint
	iter::Cint
	obj::Cdouble
	hard_case::Cuchar
	multiplier::Cdouble
	mnormx::Cdouble
end

function getHessianLowerTriangularPart(H)
	h_vec = Vector{Float64}()
	for i in 1:size(H)[1]
		for j in 1:i
			push!(h_vec, H[i, j])
		end
	end
	return h_vec
end

function solveTrustRegionSubproblem(f::Float64, g::Vector{Float64}, H, x_k::Vector{Float64}, δ::Float64, ϵ::Float64, r::Float64, min_grad::Float64, problem_name::String, subproblem_solver_method::String=subproblem_solver_methods.OPTIMIZATION_METHOD_DEFAULT, print_level::Int64=0)
	if subproblem_solver_method == OPTIMIZATION_METHOD_DEFAULT
		return optimizeSecondOrderModel(g, H, δ, ϵ, r, print_level)
	end

	if subproblem_solver_method == OPTIMIZATION_METHOD_TRS
		return trs(f, g, H, δ, ϵ, r, problem_name, print_level)
	end

	if subproblem_solver_method == OPTIMIZATION_METHOD_GLTR
		return gltr(f, g, H, r, min_grad, print_level)
	end

	return optimizeSecondOrderModel(g, H, δ, ϵ, r, print_level)
end

function trs(f::Float64, g::Vector{Float64}, H, δ::Float64, ϵ::Float64, r::Float64, problem_name::String, print_level::Int64=0)
    max_factorizations = 1000
	H_dense = getHessianLowerTriangularPart(H)
	d = zeros(length(g))
	full_Path = string(@__DIR__ ,"/test")
	use_initial_multiplier = true
	initial_multiplier = δ
	use_stop_args = true
	stop_normal = 1e-5
    stop_hard = 1e-5

	# Convert the Julia string to a C-compatible representation (Cstring)
	string_problem_name = string(@__DIR__ ,"/../DEBUG_TRS/$problem_name.csv")
	if print_level >= 0
		if_mkpath(string(@__DIR__ ,"/../DEBUG_TRS"))
		if !isfile(string_problem_name)
			open(string_problem_name,"a") do iteration_status_csv_file
				write(iteration_status_csv_file, "status,hard_case,x_norm,radius,multiplier,lambda,len_history,factorizations\n");
	    	end
		end
	end
	userdata = ccall((:trs, LIBRARY_PATH_TRS), userdata_type_trs, (Cint, Cdouble, Ref{Cdouble}, Ref{Cdouble}, Ref{Cdouble}, Cdouble, Cint, Cint, Cuchar, Cdouble, Cuchar, Cdouble, Cdouble, Cstring), length(g), f, d, g, H_dense, r, print_level, max_factorizations, use_initial_multiplier, initial_multiplier, use_stop_args, stop_normal, stop_hard, string_problem_name)

	tol = 1e-1
	condition_success = norm(d, 2) - r <= tol || abs(norm(d, 2) - r) <= stop_normal * r + tol || abs(norm(d, 2) - r) <= stop_normal + tol

	if userdata.status != 0 || !condition_success
		if print_level >= 1
			println("Failed to solve trust region subproblem using TRS factorization method from GALAHAD. Status is $(userdata.status).")
		end
		if userdata.status == 0
			norm_d = norm(d, 2)
			@warn "Solution isn't inside the trust-region. ||d_k|| = $norm_d but radius is $r."
			if print_level >= 1
				println("Solution isn't inside the trust-region. ||d_k|| = $norm_d but radius is $r.")
			end
		else
			if print_level >= 1
				@warn "Failed to solve trust region subproblem using TRS factorization method from GALAHAD. Status is $(userdata.status)."
			end
		end
		δ = max(δ, abs(eigmin(Matrix(H))))
		try
			success, δ, d_k, total_number_factorizations, hard_case = optimizeSecondOrderModel(g, H, δ, stop_normal, r, print_level)
			return success, δ, d_k, total_number_factorizations + userdata.factorizations, hard_case
		catch
			if e == ErrorException("Bisection logic failed to find a root for the phi function")
				if eigmin(Matrix(H)) >= 0
					@error e
				end
				success, δ, d_k, total_number_factorizations, hard_case = optimizeSecondOrderModel(g, H, δ, ϵ, r, print_level)
				return success, δ, d_k, total_number_factorizations + userdata.factorizations, hard_case
			end
			@error e
			throw(e)
		end
	end

    multiplier = userdata.multiplier
	hard_case = Bool(userdata.hard_case != 0)
    return true, multiplier, d, userdata.factorizations, hard_case
end

function gltr(f::Float64, g::Vector{Float64}, H, r::Float64, min_grad::Float64, print_level::Int64=0)
    iter = 10000
	H_dense = getHessianLowerTriangularPart(H)
	d = zeros(length(g))
	stop_relative = 1.5e-8
	stop_relative = min(1e-6 * min_grad, 1e-6)
	stop_absolute = 0.0
	steihaug_toint = false
	stop_absolute = 0.0
	stop_relative = 0.0
	userdata = ccall((:gltr, LIBRARY_PATH_GLTR), userdata_type_gltr, (Cint, Cdouble, Ref{Cdouble}, Ref{Cdouble}, Ref{Cdouble}, Cdouble, Cint, Cint, Cdouble, Cdouble, Cuchar), length(g), f, d, g, H_dense, r, print_level, iter, stop_relative, stop_absolute, steihaug_toint)
	if userdata.status < 0
		steihaug_toint = true
		stop_relative = min(0.1 * min_grad, 0.1)
		d = zeros(length(g))
		userdata = ccall((:gltr, LIBRARY_PATH_GLTR), userdata_type_gltr, (Cint, Cdouble, Ref{Cdouble}, Ref{Cdouble}, Ref{Cdouble}, Cdouble, Cint, Cint, Cdouble, Cdouble, Cuchar), length(g), f, d, g, H_dense, r, print_level, iter, stop_relative, stop_absolute, steihaug_toint)
	end
	if userdata.status != 0
		throw(error("Failed to solve trust region subproblem using GLTR iterative method from GALAHAD. Status is $(userdata.status)."))
	end
	return true, userdata.multiplier, d, userdata.iter, false
end

#Based on Theorem 4.3 in Numerical Optimization by Wright

function computeSearchDirection(g::Vector{Float64}, H, δ::Float64, ϵ::Float64, r::Float64, total_number_factorizations::Int64, print_level::Int64=0)
	δ, δ_prime, temp_total_number_factorizations = findinterval(g, H, δ, ϵ, r, print_level)
	total_number_factorizations += temp_total_number_factorizations
	δ_m, temp_total_number_factorizations = bisection(g, H, δ, ϵ, δ_prime, r, print_level)
	total_number_factorizations += temp_total_number_factorizations
	sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
	total_number_factorizations  += 1
	d_k = (cholesky(H + δ_m * sparse_identity) \ (-g))
	return true, δ_m, d_k, total_number_factorizations, false
end

function optimizeSecondOrderModel(g::Vector{Float64}, H, δ::Float64, ϵ::Float64, r::Float64, print_level::Int64=0)
    #When δ is 0 and the Hessian is positive semidefinite, we can directly compute the direction
    total_number_factorizations = 0
    try
		total_number_factorizations += 1
        cholesky(Matrix(H))
        d_k = H \ (-g)
        if norm(d_k, 2) <= (1 + ϵ) * r
        	return true, 0.0, d_k, total_number_factorizations, false
        end
    catch e
		#Do nothing
    end
    try
		return computeSearchDirection(g, H, δ, ϵ, r, total_number_factorizations, print_level)
    catch e
		println("Error: ", e)
        if e == ErrorException("Bisection logic failed to find a root for the phi function")
			if eigmin(Matrix(H)) >= 0 && ϵ != 0.1
				try
					return computeSearchDirection(g, H, δ, 0.1, r, total_number_factorizations, print_level)
				catch e_
					@error e_
				end
			end
	    	success, δ, d_k, temp_total_number_factorizations = solveHardCaseLogic(g, H, ϵ, r, print_level)
			total_number_factorizations += total_number_factorizations
            return success, δ, d_k, total_number_factorizations, true
        elseif e == ErrorException("Bisection logic failed to find a pair δ and δ_prime such that ϕ(δ) >= 0 and ϕ(δ_prime) <= 0.")
			@error e
            success, δ, d_k, temp_total_number_factorizations = solveHardCaseLogic(g, H, ϵ, r, print_level)
			total_number_factorizations += temp_total_number_factorizations
	    	return success, δ, d_k, total_number_factorizations, true
        else
			@error e
            throw(e)
        end
    end
end


function phi(g::Vector{Float64}, H, δ::Float64, ϵ::Float64, r::Float64, print_level::Int64=0)
    sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
    shifted_hessian = H + δ * sparse_identity
    #cholesky factorization only works on positive definite matrices
    try
        cholesky(shifted_hessian)
        computed_norm = norm(shifted_hessian \ g, 2)
		if (δ <= 1e-6 && computed_norm <= r)
			return 0
		elseif computed_norm < (1 -ϵ) * r
	        return -1
		# elseif computed_norm <= (2 - ϵ) * r
		elseif abs(computed_norm - r) <= ϵ * r
	        return 0
	    else
	        return 1
	    end
    catch e
        return 1
    end
end

function findinterval(g::Vector{Float64}, H, δ::Float64, ϵ::Float64, r::Float64, print_level::Int64=0)
	if print_level >= 1
		println("STARTING WITH δ = $δ.")
	end
    Φ_δ = phi(g, H, 0.0, ϵ, r)

    if Φ_δ == 0
        δ = 0.0
        δ_prime = 0.0
        return δ, δ_prime, 1
    end

	δ_original = δ

	if δ_original < 1e-6
		δ = 1e-2 * sqrt(δ)
	end
	if print_level >= 1
		println("Updating δ to δ = $δ.")
	end

    Φ_δ = phi(g, H, δ, ϵ, r)

    if Φ_δ == 0
        δ_prime = δ
        return δ, δ_prime, 2
    end

    δ_prime = δ == 0.0 ? 1.0 : δ * 2
	if Φ_δ > 0
		if δ != 0.0
			if δ_original < 1e-6
				δ_prime = 1e-1 * sqrt(δ)
			else
				δ_prime = δ * 2 ^ 5
			end
		end
	else
		if δ != 0.0
			if δ_original < 1e-6
				δ_prime = 0.0
			else
				δ_prime = δ / 2 ^ 5
			end
		end
	end
	if δ < 0
		δ_prime = -δ
	end
    Φ_δ_prime = 0.0
	max_iterations = 1000
    k = 1
    while k < max_iterations
        Φ_δ_prime = phi(g, H, δ_prime, ϵ, r)
        if Φ_δ_prime == 0
            δ = δ_prime
            return δ, δ_prime, k + 2
        end

        if ((Φ_δ * Φ_δ_prime) < 0)
			if print_level >= 1
				println("ENDING WITH ϕ(δ) = $Φ_δ and Φ_δ_prime = $Φ_δ_prime.")
				println("ENDING WITH δ = $δ and δ_prime = $δ_prime.")
			end
            break
        end
        if Φ_δ_prime < 0
            δ_prime = δ_prime / 2
        elseif Φ_δ_prime > 0
            δ_prime = δ_prime * 2
        end
        k = k + 1
    end

    #switch so that δ for ϕ_δ >= 0 and δ_prime for ϕ_δ_prime <= 0
	#δ < δ_prime since ϕ is decreasing function
    if Φ_δ_prime > 0 && Φ_δ < 0
        δ_temp = δ
        Φ_δ_temp = Φ_δ
        δ = δ_prime
        δ_prime = δ_temp
        Φ_δ = Φ_δ_prime
        Φ_δ_prime = Φ_δ_temp
    end

    if (Φ_δ  * Φ_δ_prime > 0)
		if print_level >= 1
			println("Φ_δ is $Φ_δ and Φ_δ_prime is $Φ_δ_prime. δ is $δ and δ_prime is $δ_prime.")
		end
        throw(error("Bisection logic failed to find a pair δ and δ_prime such that ϕ(δ) >= 0 and ϕ(δ_prime) <= 0."))
    end

	if δ > δ_prime
		δ_temp = δ
        δ = δ_prime
		δ_prime = δ_temp
	end

    return δ, δ_prime, min(k, max_iterations) + 2
end

function bisection(g::Vector{Float64}, H, δ::Float64, ϵ::Float64, δ_prime::Float64, r::Float64, print_level::Int64=0)
    # the input of the function is the two end of the interval (δ,δ_prime)
    # our goal here is to find the approximate δ using classic bisection method
	if print_level >= 0
		println("****************************STARTING BISECTION with (δ, δ_prime) = ($δ, $δ_prime)**************")
	end
    #Bisection logic
    k = 1
    δ_m = (δ + δ_prime) / 2
    Φ_δ_m = phi(g, H, δ_m, ϵ, r)
	max_iterations = 1000
	#ϕ_δ >= 0 and ϕ_δ_prime <= 0
    while (Φ_δ_m != 0) && k <= max_iterations
        if Φ_δ_m > 0
            δ = δ_m
        else
            δ_prime = δ_m
        end
        δ_m = (δ + δ_prime) / 2
        Φ_δ_m = phi(g, H, δ_m, ϵ, r)
		if Φ_δ_m != 0 && abs(δ - δ_prime) <= 1e-11
			δ_prime = 2 * δ_prime
			δ = δ / 2
		end
		# println("****************************BISECTION with (δ, δ_prime) = ($δ, $δ_prime)**************")
        k = k + 1
    end

    if (Φ_δ_m != 0)
		if print_level >= 1
			println("Φ_δ_m is $Φ_δ_m.")
			println("δ, δ_prime, and δ_m are $δ, $δ_prime, and $δ_m. ϵ is $ϵ.")
		end
        throw(error("Bisection logic failed to find a root for the phi function"))
    end
	if print_level >= 0
		println("****************************ENDING BISECTION with δ_m = $δ_m**************")
	end
    return δ_m, min(k, max_iterations) + 1
end

#Based on 'THE HARD CASE' section from Numerical Optimization by Wright
function solveHardCaseLogic(g::Vector{Float64}, H, ϵ::Float64, r::Float64, print_level::Int64=0)
    minimumEigenValue = eigmin(Matrix(H))
	if minimumEigenValue >= 0
		Q = eigvecs(Matrix(H))
		eigenvaluesVector = eigvals(Matrix(H))

		temp_d_0 = zeros(length(g))
		for i in 1:length(eigenvaluesVector)
			temp_d_0 = temp_d_0 .- ((Q[:, i]' * g) / (eigenvaluesVector[i] + 0)) * Q[:, i]
	    end

		temp_d_0_norm = norm(temp_d_0, 2)
		less_than_radius = temp_d_0_norm <= r
		if print_level >= 1
			println("temp_d_0_norm is $temp_d_0_norm and ||d(0)|| <= r is $less_than_radius.")
		end
		if less_than_radius
			return  true, 0.0, temp_d_0, 0
		end
		if print_level >= 1
			println("minimumEigenValue is $minimumEigenValue")
			println("r is $r")
			println("g is $g")
			H_matrix = Matrix(H)
			println("H is $H_matrix")
		end
		return false, minimumEigenValue, zeros(length(g)), 0
	end
    δ = -minimumEigenValue
	try
		Q = eigvecs(Matrix(H))
		z =  Q[:,1]
		temp_ = dot(z', g)
		if print_level >= 1
			println("Q_1 ^ T g = $temp_.")
			println("minimumEigenValue = $minimumEigenValue.")
		end
	    eigenvaluesVector = eigvals(Matrix(H))

		temp_d_0 = zeros(length(g))
		for i in 1:length(eigenvaluesVector)
	        temp_d_0 = temp_d_0 .- ((Q[:, i]' * g) / (eigenvaluesVector[i] + 0)) * Q[:, i]
	    end

		temp_d_0_norm = norm(temp_d_0, 2)
		less_than_radius = temp_d_0_norm <= r
		if print_level >= 1
			println("temp_d_0_norm is $temp_d_0_norm and ||d(0)|| <= r is $less_than_radius.")
		end

		temp_d = zeros(length(g))
		for i in 1:length(eigenvaluesVector)
			if eigenvaluesVector[i] != minimumEigenValue
	            temp_d = temp_d .- ((Q[:, i]' * g) / (eigenvaluesVector[i] + δ)) * Q[:, i]
	        end
	    end

		temp_d_norm = norm(temp_d, 2)
		less_than_radius_ = temp_d_norm < r
		if print_level >= 1
			println("temp_d_norm is $temp_d_norm and ||d(-λ_1)|| < r is $less_than_radius_.")
		end

		if !less_than_radius_
			if print_level >= 0
				println("This is not a hard case sub-problem.")
			end
			@error "This is not a hard case sub-problem."
			try
				temp_success, δ_m, d_k, total_number_factorizations, temp_hard_case  = computeSearchDirection(g, H, δ, ϵ, r, 0, print_level)
				return true, δ_m, d_k, total_number_factorizations
			catch e
				@error e
			end
		end

	    norm_d_k_squared_without_τ_squared = 0.0

	    for i in 1:length(eigenvaluesVector)
	        if eigenvaluesVector[i] != minimumEigenValue
	            norm_d_k_squared_without_τ_squared = norm_d_k_squared_without_τ_squared + ((Q[:, i]' * g) ^ 2 / (eigenvaluesVector[i] + δ) ^ 2)
	        end
	    end

	    norm_d_k_squared = r ^ 2
		if norm_d_k_squared < norm_d_k_squared_without_τ_squared && print_level >= 1
			println("norm_d_k_squared is $norm_d_k_squared and norm_d_k_squared_without_τ_squared is $norm_d_k_squared_without_τ_squared.")
		end

		if norm_d_k_squared < norm_d_k_squared_without_τ_squared
			if less_than_radius
				if print_level >= 1
					println("HAD CASE LOGIC: δ, d_k and r are $δ, $temp_d_norm, and $r.")
				end
				return true, δ, temp_d, 0
			end
			if print_level >= 1
				println("minimumEigenValue is $minimumEigenValue")
				println("r is $r")
				println("g is $g")
				H_matrix = Matrix(H)
				println("H is $H_matrix")
			end
			return false, δ, zeros(length(g)), 0
		end

	    τ = sqrt(norm_d_k_squared - norm_d_k_squared_without_τ_squared)
	    d_k = τ .* z

	    for i in 1:length(eigenvaluesVector)
	        if eigenvaluesVector[i] != minimumEigenValue
	            d_k = d_k .- ((Q[:, i]' * g) / (eigenvaluesVector[i] + δ)) * Q[:, i]
	        end
	    end
		temp_norm_d_k = norm(d_k, 2)
		if print_level >= 1
			println("HAD CASE LOGIC: δ, d_k and r are $δ, $temp_norm_d_k, and $r.")
		end
	    return true, δ, d_k, 0
	catch e
		@show e
		if print_level >= 1
			println("minimumEigenValue is $minimumEigenValue")
			println("r is $r")
			println("g is $g")
			H_matrix = Matrix(H)
			println("H is $H_matrix")
		end
		return false, δ, zeros(length(g)), 0
	end

end
