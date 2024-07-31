export phi, findinterval, bisection
using LinearAlgebra
using Dates

#=
The big picture idea here is to optimize the trust region subproblem using a factorization method based
on the optimality conditions:
H d_k + g + δ d_k = 0
H + δ I ≥ 0
δ(r -  ||d_k ||) = 0

That is why we defined the below phi to solve that using bisection logic.
=#

function if_mkpath(dir::String)
  if !isdir(dir)
     mkpath(dir)
  end
end

function solveTrustRegionSubproblem(
	f::Float64, g::Vector{Float64},
	H::Union{Matrix{Float64}, SparseMatrixCSC{Float64, Int64}, Symmetric{Float64, SparseMatrixCSC{Float64, Int64}}},
	x_k::Vector{Float64}, δ::Float64, γ_2::Float64, r::Float64, min_grad::Float64, print_level::Int64=0
	)
	return optimizeSecondOrderModel(g, H, δ, γ_2, r, min_grad, print_level)
end

function computeSearchDirection(
	g::Vector{Float64},
	H::Union{Matrix{Float64}, SparseMatrixCSC{Float64, Int64}, Symmetric{Float64, SparseMatrixCSC{Float64, Int64}}},
	δ::Float64, γ_2::Float64, r::Float64, min_grad::Float64, print_level::Int64=0
	)
	temp_total_number_factorizations_bisection = 0
	temp_total_number_factorizations_findinterval = 0
	temp_total_number_factorizations_compute_search_direction = 0
	temp_total_number_factorizations_ = 0
	start_time_temp = time()
	if print_level >= 2
		println("Starting Find Interval")
	end
	success, δ, δ_prime, temp_total_number_factorizations_findinterval = findinterval(g, H, δ, γ_2, r, print_level)
	temp_total_number_factorizations_ += temp_total_number_factorizations_findinterval
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	if print_level >= 2
		println("findinterval operation finished with (δ, δ_prime) = ($δ, $δ_prime) and took $total_time_temp.")
	end

	if !success
		@assert temp_total_number_factorizations_ == temp_total_number_factorizations_findinterval + temp_total_number_factorizations_bisection + temp_total_number_factorizations_compute_search_direction
		return false, false, δ, δ, δ_prime, zeros(length(g)), temp_total_number_factorizations_, false, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction
	end

	start_time_temp = time()
	success, δ_m, δ, δ_prime, temp_total_number_factorizations_bisection = bisection(g, H, δ, γ_2, δ_prime, r, min_grad, print_level)
	temp_total_number_factorizations_ += temp_total_number_factorizations_bisection
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	if print_level >= 2
		println("$success. bisection operation took $total_time_temp.")
	end

	if !success
		@assert temp_total_number_factorizations_ == temp_total_number_factorizations_findinterval + temp_total_number_factorizations_bisection + temp_total_number_factorizations_compute_search_direction
		return true, false, δ_m, δ, δ_prime, zeros(length(g)), temp_total_number_factorizations_, false, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction
	end

	@assert δ <= δ_m <= δ_prime

	sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
	temp_total_number_factorizations_compute_search_direction += 1
	temp_total_number_factorizations_ += temp_total_number_factorizations_compute_search_direction

	start_time_temp = time()
	d_k = cholesky(H + δ_m * sparse_identity) \ (-g)
	end_time_temp = time()
	total_time_temp = end_time_temp - start_time_temp
	if print_level >= 2
		println("d_k operation took $total_time_temp.")
	end
	@assert temp_total_number_factorizations_ == temp_total_number_factorizations_findinterval + temp_total_number_factorizations_bisection + temp_total_number_factorizations_compute_search_direction
	return true, true, δ_m, δ, δ_prime, d_k, temp_total_number_factorizations_, false, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction
end

function optimizeSecondOrderModel(
	g::Vector{Float64},
	H::Union{Matrix{Float64}, SparseMatrixCSC{Float64, Int64}, Symmetric{Float64, SparseMatrixCSC{Float64, Int64}}},
	δ::Float64, γ_2::Float64, r::Float64, min_grad::Float64, print_level::Int64=0
	)
    #When δ is 0 and the Hessian is positive semidefinite, we can directly compute the direction
	total_number_factorizations = 0
	temp_total_number_factorizations_findinterval = 0
	temp_total_number_factorizations_bisection = 0
	temp_total_number_factorizations_compute_search_direction = 0
	temp_total_number_factorizations_inverse_power_iteration = 0
	temp_total_number_factorizations_ = 0
    try
		temp_total_number_factorizations_compute_search_direction += 1
		temp_total_number_factorizations_ += temp_total_number_factorizations_compute_search_direction
        d_k = cholesky(H) \ (-g)
		if norm(d_k, 2) <= r
			@assert temp_total_number_factorizations_ == temp_total_number_factorizations_findinterval + temp_total_number_factorizations_bisection + temp_total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
			total_number_factorizations += temp_total_number_factorizations_
			return true, 0.0, d_k, total_number_factorizations, false, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
        end
    catch e
		#Do nothing
    end
	δ_m = δ
	δ_prime = δ
    try
		success_find_interval, success_bisection, δ_m, δ, δ_prime, d_k, temp_total_number_factorizations, hard_case, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, total_number_factorizations_compute_search_direction = computeSearchDirection(g, H, δ, γ_2, r, min_grad, print_level)
		@assert temp_total_number_factorizations == temp_total_number_factorizations_findinterval + temp_total_number_factorizations_bisection + total_number_factorizations_compute_search_direction
		temp_total_number_factorizations_compute_search_direction += total_number_factorizations_compute_search_direction # TO ACCOUNT FOR THE FIRST ATTEMP WITH d_k = cholesky(H) \ (-g)
		temp_total_number_factorizations_ += temp_total_number_factorizations
		success = success_find_interval && success_bisection
		if success
			@assert temp_total_number_factorizations_ == temp_total_number_factorizations_findinterval + temp_total_number_factorizations_bisection + temp_total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
			total_number_factorizations += temp_total_number_factorizations_
			return true, δ_m, d_k, total_number_factorizations, hard_case, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
		end
		if success_find_interval
			throw(error("Bisection logic failed to find a root for the phi function"))
		else
			throw(error("Bisection logic failed to find a pair δ and δ_prime such that ϕ(δ) >= 0 and ϕ(δ_prime) <= 0."))
		end
    catch e
		println("Error: ", e)
        if e == ErrorException("Bisection logic failed to find a root for the phi function")
			start_time_temp = time()
			success, δ, d_k, temp_total_number_factorizations, total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration = solveHardCaseLogic(g, H, γ_2, r, δ, δ_prime, min_grad, print_level)
			@assert temp_total_number_factorizations == total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
			temp_total_number_factorizations_compute_search_direction += total_number_factorizations_compute_search_direction
			temp_total_number_factorizations_ += temp_total_number_factorizations
			end_time_temp = time()
			total_time_temp = end_time_temp - start_time_temp
			if print_level >= 2
				@info "$success. solveHardCaseLogic operation took $total_time_temp."
				println("$success. solveHardCaseLogic operation took $total_time_temp.")
			end
			@assert temp_total_number_factorizations_ == temp_total_number_factorizations_findinterval + temp_total_number_factorizations_bisection + temp_total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
			total_number_factorizations += temp_total_number_factorizations_
            return success, δ, d_k, total_number_factorizations, true, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
        elseif e == ErrorException("Bisection logic failed to find a pair δ and δ_prime such that ϕ(δ) >= 0 and ϕ(δ_prime) <= 0.")
			@error e
			start_time_temp = time()
			success, δ, d_k, temp_total_number_factorizations, total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration = solveHardCaseLogic(g, H, γ_2, r, δ, δ_prime, min_grad, print_level)
			@assert temp_total_number_factorizations == total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
			temp_total_number_factorizations_compute_search_direction += total_number_factorizations_compute_search_direction
			temp_total_number_factorizations_ += temp_total_number_factorizations
			end_time_temp = time()
			total_time_temp = end_time_temp - start_time_temp
			if print_level >= 2
				@info "$success. solveHardCaseLogic operation took $total_time_temp."
				println("$success. solveHardCaseLogic operation took $total_time_temp.")
			end
			@assert temp_total_number_factorizations_ == temp_total_number_factorizations_findinterval + temp_total_number_factorizations_bisection + temp_total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
			total_number_factorizations += temp_total_number_factorizations_
	    	return success, δ, d_k, total_number_factorizations, true, temp_total_number_factorizations_findinterval, temp_total_number_factorizations_bisection, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
        else
			@error e
            throw(e)
        end
    end
end

function phi(
	g::Vector{Float64},
	H::Union{Matrix{Float64}, SparseMatrixCSC{Float64, Int64}, Symmetric{Float64, SparseMatrixCSC{Float64, Int64}}},
	δ::Float64, γ_2::Float64, r::Float64, print_level::Int64=0
	)
    sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
    shifted_hessian = H + δ * sparse_identity
	temp_d = zeros(length(g))
	positive_definite = true
    try
		start_time_temp = time()
        shifted_hessian_fact = cholesky(shifted_hessian)
		end_time_temp = time()
		total_time_temp = end_time_temp - start_time_temp
		if print_level >= 2
			println("cholesky inside phi function took $total_time_temp.")
		end

		start_time_temp = time()
		temp_d = shifted_hessian_fact \ (-g)
		computed_norm = norm(temp_d, 2)
		end_time_temp = time()
		total_time_temp = end_time_temp - start_time_temp
		if print_level >= 2
			println("computed_norm opertion took $total_time_temp.")
		end

		if (δ <= 1e-6 && computed_norm <= r)
			return 0, temp_d, positive_definite
		elseif computed_norm < γ_2 * r
	        return -1, temp_d, positive_definite
		elseif computed_norm <= r
	        return 0, temp_d, positive_definite
	    else
	        return 1, temp_d, positive_definite
	    end
    catch e
		positive_definite = false
        return 1, temp_d, positive_definite
    end
end

function findinterval(
	g::Vector{Float64},
	H::Union{Matrix{Float64}, SparseMatrixCSC{Float64, Int64}, Symmetric{Float64, SparseMatrixCSC{Float64, Int64}}},
	δ::Float64, γ_2::Float64, r::Float64, print_level::Int64=0
	)
	@assert δ >= 0
	if print_level >= 1
		println("STARTING WITH δ = $δ.")
	end
    Φ_δ, temp_d, positive_definite = phi(g, H, 0.0, γ_2, r)

    if Φ_δ == 0
        δ = 0.0
        δ_prime = 0.0
        return true, δ, δ_prime, 1
    end

	δ_original = δ

    Φ_δ, temp_d, positive_definite = phi(g, H, δ, γ_2, r)

    if Φ_δ == 0
        δ_prime = δ
        return true, δ, δ_prime, 2
    end

	δ_prime = δ
	Φ_δ_prime = Φ_δ
	search_δ_prime = true

	if Φ_δ > 0
		δ_prime = δ == 0.0 ? 1.0 : δ * 2
		search_δ_prime = true
	else
		# Here ϕ(δ) < 0 and we need to find new δ' >= 0 such that ϕ(δ') >= 0 and δ' < δ which is not possible
		# in case δ == 0
		@assert δ > 0
		search_δ_prime = false
		# The aim is to find [δ, δ'] such that ϕ(δ) ∈ {0, 1}, ϕ(δ') ∈ {0, -1}, and  ϕ(δ) * ϕ(δ') <= ∈ {0, -1}
		# since here ϕ(δ) < 0, we set δ' = δ and we search for δ < δ'such that ϕ(δ) ∈ {0, 1}
		δ_prime = δ
		Φ_δ_prime = -1
		δ = δ / 2
	end

	max_iterations = 50
    k = 1
	while k < max_iterations
		if search_δ_prime
        	Φ_δ_prime, temp_d, positive_definite = phi(g, H, δ_prime, γ_2, r)
	        if Φ_δ_prime == 0
	            δ = δ_prime
	            return true, δ, δ_prime, k + 2
	        end
		else
			Φ_δ, temp_d, positive_definite = phi(g, H, δ, γ_2, r)
			if Φ_δ == 0
	            δ_prime = δ
	            return true, δ, δ_prime, k + 2
	        end
		end

        if ((Φ_δ * Φ_δ_prime) < 0)
			if print_level >= 1
				println("ENDING WITH ϕ(δ) = $Φ_δ and Φ_δ_prime = $Φ_δ_prime.")
				println("ENDING WITH δ = $δ and δ_prime = $δ_prime.")
			end
			@assert δ_prime > δ
			@assert ((δ == 0.0) & (δ_prime == 1.0)) || ((δ_prime / δ) == 2 ^ (2 ^ (k - 1))) || ((δ_prime / δ) - 2 ^ (2 ^ (k - 1)) <= 1e-3)
			factor = δ_prime / δ
			return true, δ, δ_prime, k + 2
        end
		if search_δ_prime
			# Here Φ_δ_prime is still 1 and we are continue searching for δ',
			# but we can update δ to give it larger values which is the current value of δ'
			@assert Φ_δ_prime > 0
			δ = δ_prime
			δ_prime = δ_prime * (2 ^ (2 ^ k))
		else
			# Here Φ_δ is still -1 and we are continue searching for δ,
			# but we can update δ' to give it smaller value which is the current value of δ
			@assert Φ_δ < 0
			δ_prime = δ
			δ = δ / (2 ^ (2 ^ k))
		end

        k = k + 1
    end

    if (Φ_δ  * Φ_δ_prime > 0)
		if print_level >= 1
			println("Φ_δ is $Φ_δ and Φ_δ_prime is $Φ_δ_prime. δ is $δ and δ_prime is $δ_prime.")
		end
		return false, δ, δ_prime, max_iterations + 2
    end
	factor = δ_prime / δ
    return true, δ, δ_prime, max_iterations + 2
end

function bisection(
	g::Vector{Float64},
	H::Union{Matrix{Float64}, SparseMatrixCSC{Float64, Int64}, Symmetric{Float64, SparseMatrixCSC{Float64, Int64}}},
	δ::Float64, γ_2::Float64, δ_prime::Float64, r::Float64, min_grad::Float64, print_level::Int64=0
	)
    # the input of the function is the two end of the interval (δ,δ_prime)
    # our goal here is to find the approximate δ using classic bisection method
	initial_δ = δ
	initial_δ_prime = δ_prime
	if print_level >= 1
		println("****************************STARTING BISECTION with (δ, δ_prime) = ($δ, $δ_prime)**************")
	end
    #Bisection logic
    k = 1
    δ_m = (δ + δ_prime) / 2
    Φ_δ_m, temp_d, positive_definite = phi(g, H, δ_m, γ_2, r)
	max_iterations = 100
    while (Φ_δ_m != 0) && k <= max_iterations
		start_time_str = Dates.format(now(), "mm/dd/yyyy HH:MM:SS")
		if print_level >= 2
			println("$start_time_str. Bisection iteration $k.")
		end
        if Φ_δ_m > 0
            δ = δ_m
        else
            δ_prime = δ_m
        end
		δ_m = (δ + δ_prime) / 2
        Φ_δ_m, temp_d, positive_definite = phi(g, H, δ_m, γ_2, r)
        k = k + 1
        γ_1 = 100
		if Φ_δ_m != 0
			ϕ_δ_prime, d_temp_δ_prime, positive_definite_δ_prime = phi(g, H, δ_prime, γ_2, r)
			ϕ_δ, d_temp_δ, positive_definite_δ = phi(g, H, δ, γ_2, r)
			q_1 = norm(H * d_temp_δ_prime + g + δ_prime * d_temp_δ_prime)
			q_2 = min_grad / γ_1
			if print_level >= 2
				println("$k===============Bisection entered here=================")
			end

			if (abs(δ_prime - δ) <= (min_grad / (1000 * r))) && q_1 <= q_2 && !positive_definite_δ
				if print_level >= 2
					println("$k===================norm(H * d_temp_δ_prime + g + δ_prime * d_temp_δ_prime) is $q_1.============")
					println("$k===================min_grad / (100 r) is $q_2.============")
					println("$k===================ϕ_δ_prime is $ϕ_δ_prime.============")

					println("$k===============Bisection entered here=================")
					mimimum_eigenvalue = eigmin(Matrix(H))
					mimimum_eigenvalue_abs = abs(mimimum_eigenvalue)
					@info "$k=============Bisection Failure New Logic==============$initial_δ,$δ,$mimimum_eigenvalue,$mimimum_eigenvalue_abs."
					println("$k=============Bisection Failure New Logic==============$initial_δ,$δ,$mimimum_eigenvalue,$mimimum_eigenvalue_abs.")
				end
				break
			end
		end
    end

    if (Φ_δ_m != 0)
		if print_level >= 1
			println("Φ_δ_m is $Φ_δ_m.")
			println("δ, δ_prime, and δ_m are $δ, $δ_prime, and $δ_m. γ_2 is $γ_2.")
		end
		return false, δ_m, δ, δ_prime, min(k, max_iterations) + 1
    end
	if print_level >= 1
		println("****************************ENDING BISECTION with δ_m = $δ_m**************")
	end
    return true, δ_m, δ, δ_prime, min(k, max_iterations) + 1
end

function solveHardCaseLogic(
	g::Vector{Float64},
	H::Union{SparseMatrixCSC{Float64, Int64}, Symmetric{Float64, SparseMatrixCSC{Float64, Int64}}},
	γ_2::Float64, r::Float64, δ::Float64, δ_prime::Float64, min_grad::Float64, print_level::Int64=0
	)
	sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
	total_number_factorizations = 0
	temp_total_number_factorizations_compute_search_direction = 0
	temp_total_number_factorizations_inverse_power_iteration = 0
	temp_total_number_factorizations_ = 0

	temp_eigenvalue = 0
	try
		start_time_temp = time()
		success, eigenvalue, eigenvector, temp_total_number_factorizations_inverse_power_iteration, temp_d_k = inverse_power_iteration(g, H, min_grad, δ, δ_prime, r, γ_2)
		temp_eigenvalue = eigenvalue
		end_time_temp = time()
	    total_time_temp = end_time_temp - start_time_temp
		if print_level >= 2
	    	@info "inverse_power_iteration operation took $total_time_temp."
		end
		eigenvalue = abs(eigenvalue)
		temp_total_number_factorizations_ += temp_total_number_factorizations_inverse_power_iteration
		norm_temp_d_k = norm(temp_d_k)

		if norm_temp_d_k == 0
			@assert temp_total_number_factorizations_ == temp_total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
			total_number_factorizations += temp_total_number_factorizations_
			return false, eigenvalue, zeros(length(g)), total_number_factorizations, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
		end

		if print_level >= 2
			@info "candidate search direction norm is $norm_temp_d_k. r is $r. γ_2 is $γ_2"
		end
		if γ_2 * r <= norm(temp_d_k) <= r
			@assert temp_total_number_factorizations_ == temp_total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
			total_number_factorizations += temp_total_number_factorizations_
			return true, eigenvalue, temp_d_k, total_number_factorizations, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
		end
		if norm(temp_d_k) > r
			if print_level >= 1
				println("This is noit a hard case. FAILURE======candidate search direction norm is $norm_temp_d_k. r is $r. γ_2 is $γ_2")
				@warn "This is noit a hard case. candidate search direction norm is $norm_temp_d_k. r is $r. γ_2 is $γ_2"
			end
		end

		@assert temp_total_number_factorizations_ == temp_total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
		total_number_factorizations += temp_total_number_factorizations_
		return false, eigenvalue, zeros(length(g)), total_number_factorizations, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
	catch e
		@error e
		if print_level >= 2
			matrix_H = Matrix(H)
			mimimum_eigenvalue = eigmin(Matrix(H))
			println("FAILURE+++++++inverse_power_iteration operation returned non positive matrix. retunred_eigen_value is $temp_eigenvalue and mimimum_eigenvalue is $mimimum_eigenvalue.")
		end
		@assert temp_total_number_factorizations_ ==  temp_total_number_factorizations_compute_search_direction + temp_total_number_factorizations_inverse_power_iteration
		total_number_factorizations += temp_total_number_factorizations_
		return false, δ_prime, zeros(length(g)), total_number_factorizations, temp_total_number_factorizations_compute_search_direction, temp_total_number_factorizations_inverse_power_iteration
	end
end

function inverse_power_iteration(
	g::Vector{Float64},
	H::Union{SparseMatrixCSC{Float64, Int64}, Symmetric{Float64, SparseMatrixCSC{Float64, Int64}}},
	min_grad::Float64, δ::Float64, δ_prime::Float64, r::Float64, γ_2::Float64;
	max_iter::Int64=1000, ϵ::Float64=1e-3, print_level::Int64=2
	)
   sigma = δ_prime
   start_time_temp = time()
   n = size(H, 1)
   x = ones(n)
   y = ones(n)
   sparse_identity = SparseMatrixCSC{Float64}(LinearAlgebra.I, size(H)[1], size(H)[2])
   y_original_fact = cholesky(H + sigma * sparse_identity)
   temp_factorization = 1
   for k in 1:max_iter
       y = y_original_fact \ x
       y /= norm(y)
	   eigenvalue = dot(y, H * y)

	   if norm(H * y + δ_prime * y) <= abs(δ_prime - δ) + (min_grad / (10 ^ 2 * r))
		   try
			   temp_factorization += 1
			   temp_d_k =  cholesky(H + (abs(eigenvalue) + 1e-1) * sparse_identity) \ (-g)
       		   return true, eigenvalue, y, temp_factorization, temp_d_k
		   catch
			   #DO NOTHING
		   end
	   end

	   #Keep as a safety check. This a sign that we can't solve the trust region subprobelm
       if norm(x + y) <= ϵ || norm(x - y) <= ϵ
		   eigenvalue = dot(y, H * y)
		   try
			   temp_factorization += 1
			   temp_d_k =  cholesky(H + (abs(eigenvalue) + 1e-1) * sparse_identity) \ (-g)
			   return true, eigenvalue, y, temp_factorization, temp_d_k
		   catch
			   #DO NOTHING
		   end
       end

       x = y
   end
   temp_ = dot(y, H * y)

   if print_level >= 2
	   @error ("Inverse power iteration did not converge. computed eigenValue is $temp_.")
   end

   if print_level >= 2
	   end_time_temp = time()
	   total_time_temp = end_time_temp - start_time_temp
	   @info "inverse_power_iteration operation took $total_time_temp."
	   println("inverse_power_iteration operation took $total_time_temp.")
   end

   temp_d_k = zeros(length(g))
   return false, temp_, y, temp_factorization, temp_d_k
end
