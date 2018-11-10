export FieldmapNFFTOp, createInhomogeneityData_

mutable struct FieldmapNFFTOp{T,F1<:FuncOrNothing,F2<:FuncOrNothing,F3<:FuncOrNothing} <:
                      AbstractLinearOperator{T,F1,F2,F3}
  nrow :: Int
  ncol :: Int
  symmetric :: Bool
  hermitian :: Bool
  prod :: Function
  tprod :: F1
  ctprod :: F2
  inv :: F3
  density::Vector{Float64}
end

mutable struct InhomogeneityData
  A_k::Matrix{ComplexF64}
  C_k::Matrix{ComplexF64}
  times::Vector{Float64}
  Cmap::Matrix{ComplexF64}
  t_hat::Float64
  z_hat::ComplexF64
  method::String
end

#
# Linear Operator to perform NFFT
#
function FieldmapNFFTOp(shape::NTuple{D,Int64}, tr::AbstractTrajectory,
                        correctionmap::Array{ComplexF64,D};
                        method::String="nfft",
                        symmetrize::Bool=true,
                        echoImage::Bool=true,
                        alpha::Float64=1.75,
                        m::Float64=4.0,
                        K=20) where D

  nodes,times = kspaceNodes(tr), readoutTimes(tr)
  if echoImage
    times = times .- echoTime(tr)
  end
  nrow = size(nodes,2)
  ncol = prod(shape)

 # create and truncate low-rank expansion
  cparam = createInhomogeneityData_(nrow,ncol,vec(times),correctionmap; K=K, alpha=alpha, m=m, method=method)
  K = size(cparam.A_k,2)

  @info "K = $K"

  plan = Vector{NFFTPlan{D,0,Float64}}(undef,K)
  idx = Vector{Vector{Int64}}(undef,K)
  for κ=1:K
    idx[κ] = findall(x->x!=0.0, cparam.A_k[:,κ])
    plan[κ] = NFFTPlan(nodes[:,idx[κ]], shape, 3, 1.25, precompute = NFFT.FULL)
  end

  planTmp = NFFTPlan(nodes, shape, 3, 1.25, flags = FFTW.PATIENT)
  density = convert(Vector{Float64}, sdc(planTmp))

  p = [zeros(ComplexF64, ncol) for t=1:Threads.nthreads() ]
  y = [zeros(ComplexF64, nrow) for t=1:Threads.nthreads() ]
  d = [zeros(ComplexF64, length(idx[κ])) for κ=1:K ]

  mul(x::Vector{T}) where T<:ComplexF64 =
     produ(x,nrow,ncol,shape,plan,idx,cparam,density,symmetrize,p,y,d)
  ctmul(y::Vector{T}) where T<:ComplexF64 =
     ctprodu(y,shape,plan,idx,cparam,density,symmetrize,isCircular(tr),p,y,d)
  inverse(y::Vector{T}) where T<:ComplexF64 =
     inv(y,shape,plan,idx,cparam,density,symmetrize,isCircular(tr),p,y,d)

  return FieldmapNFFTOp{ComplexF64,Nothing,Function,Function}(nrow, ncol, false, false
            , mul
            , nothing
            , ctmul
            , inverse
            , density )
end

# function produ{T<:ComplexF64}(x::Vector{T}, numOfNodes::Int, numOfPixel::Int, shape::Tuple, plan::Vector{NFFTPlan{2,0,ComplexF64}}, cparam::InhomogeneityData, density::Vector{Float64}, symmetrize::Bool)
function produ(x::Vector{T}, numOfNodes::Int, numOfPixel::Int, shape::Tuple, plan,
               idx::Vector{Vector{Int64}}, cparam::InhomogeneityData,
                density, symmetrize::Bool,p,y,d) where T<:ComplexF64
  K = size(cparam.A_k,2)
  s = zeros(ComplexF64,numOfNodes)
  # Preprocessing step when time and correctionMap are centered
  if cparam.method == "nfft"
    x_ = x .* exp.(-vec(cparam.Cmap) * cparam.t_hat )
  else
    x_ = copy(x)
  end

  sp = Threads.SpinLock()
  produ_inner(K,cparam.C_k, cparam.A_k, shape, p, d, y, s, sp, plan, idx, x_)

  # Postprocessing step when time and correctionMap are centered
  if cparam.method == "nfft"
      s[:] .*= exp.(-cparam.z_hat*(cparam.times .- cparam.t_hat) )
  end
  if symmetrize
      s[:] .*= sqrt.(density)
  end
  return s
end

function produ_inner(K, C, A, shape, p, d, y, s, sp, plan, idx, x_)
  @time Threads.@threads for κ=1:K
    t = Threads.threadid()
    for l=1:length(x_)
      p[t][l] = C[κ,l] * x_[l]
    end
    NFFT.nfft!(plan[κ], reshape(p[t][:], shape), d[κ])
    fill!(y[t], 0.0)
    for k=1:length(idx[κ])
      y[t][idx[κ][k]] = d[κ][k]
    end
    for l=1:size(A,1)
      y[t][l] *= A[l,κ]
    end
    lock(sp)
    s[:] .+= y[t]
    unlock(sp)
  end
  return
end

# function inv{T<:ComplexF64}(x::Vector{T}, shape::Tuple, plan::Vector{NFFTPlan{2,0,ComplexF64}}, cparam::InhomogeneityData, density::Vector{Float64}, symmetrize::Bool)
function inv(x::Vector{T}, shape::Tuple, plan, idx::Vector{Vector{Int64}},
             cparam::InhomogeneityData, density, symmetrize::Bool,
            shutter::Bool, p, y, d) where T<:ComplexF64
  if symmetrize
    x = x .* sqrt.(density)
  else
    x = x .* density
  end

  y = ctprodu(x,shape,plan,cparam,density,false,shutter,p,y,d)
end

# function ctprodu{T<:ComplexF64}(x::Vector{T}, shape::Tuple, plan::Vector{NFFTPlan{2,0,ComplexF64}}, cparam::InhomogeneityData, density::Vector{Float64}, symmetrize::Bool)
function ctprodu(x::Vector{T}, shape::Tuple, plan, idx::Vector{Vector{Int64}},
                 cparam::InhomogeneityData, density, symmetrize::Bool,
                 shutter::Bool, p, y_, d) where T<:ComplexF64

  y = zeros(ComplexF64,prod(shape))
  K = size(cparam.A_k,2)

  if symmetrize
    x_ = x .* sqrt.(density)
  else
    x_ = copy(x)
  end

  # Preprocessing step when time and correctionMap are centered
  if cparam.method == "nfft"
      x_[:] .*= conj.(exp.(-cparam.z_hat*(cparam.times .- cparam.t_hat)))
  end

  sp = Threads.SpinLock()
  ctprodu_inner(K,cparam.C_k, cparam.A_k, shape, p, d, y, sp, plan, idx, x_)

  if cparam.method == "nfft"
    y[:] .*=  conj(exp.(-vec(cparam.Cmap) * cparam.t_hat))
  end

  if shutter
    circularShutter!(reshape(y, shape), 1.0)
  end

  return y
end

function ctprodu_inner(K, C, A, shape, p, d, y, sp, plan, idx, x_)
  @time Threads.@threads for κ=1:K
    t = Threads.threadid()
    for k=1:length(idx[κ])
      d[κ][k] = conj.(A[idx[κ][k],κ]) * x_[idx[κ][k]]
    end
    NFFT.nfft_adjoint!(plan[κ], d[κ], reshape(p[t], shape))
    for k=1:length(p[t])
      p[t][k] = conj(C[κ,k]) * p[t][k]
    end
    lock(sp)
    y[:] .+= p[t]
    unlock(sp)
  end
  return
end

####################### Helper Function ########################################
function createInhomogeneityData_( numOfNodes::Int64,
                                  numOfPixel::Int64,
                                  times::Vector,
                                  correctionmap::Array{ComplexF64,D};
                                  K::Int64=20,
                                  alpha::Float64=1.75,
                                  m::Float64 = 4.0,
                                  method="nfft") where D

    C = getC_Coefficients_hist_lsqr(K,numOfNodes,numOfPixel,vec(times),vec(correctionmap))
    if method == "const"
      A = getA_Coefficients_one_term(K,numOfNodes,numOfPixel,vec(times),vec(correctionmap))
    elseif method== "linear"
      A = getA_Coefficients_two_terms(K,numOfNodes,numOfPixel,vec(times),vec(correctionmap))
    elseif method == "nfft"
      A,C = getA_Ccoefficients_nfft(K,numOfNodes,numOfPixel,vec(times),vec(correctionmap), alpha, m)
    elseif method == "leastsquare"
        A,C = getA_Coefficients_least_Squares(K,numOfNodes,numOfPixel,vec(times),vec(correctionmap))
    elseif method == "hist"
      A = getA_Coefficients_hist_lsqr(K,numOfNodes,numOfPixel,vec(times),vec(correctionmap))
      C = getC_Coefficients_hist_lsqr(K,numOfNodes,numOfPixel,vec(times),vec(correctionmap))
    else
      error("approximation scheme $(interp) is not yet implemented")
    end
    if size(A,2) != size(C,1)
      error("Consistency check failed! A and C are not compatible")
    end

    t_hat = (times[1] + times[end])/2
    z_hat = minimum(real(correctionmap)) + maximum(real(correctionmap))
    z_hat += 1im*(minimum(imag(correctionmap)) + maximum(imag(correctionmap)))
    z_hat *= 0.5

    return InhomogeneityData(A,C,vec(times),correctionmap,t_hat,z_hat,method)
end

function adjoint(op::FieldmapNFFTOp{T}) where T
  return LinearOperator{T,Function,Nothing,Function}(op.ncol, op.nrow, op.symmetric, op.hermitian,
                        op.ctprod, nothing, op.prod)
end
