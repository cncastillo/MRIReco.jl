# test FourierOperators
function testFT(N=16)
  # random image
  x = zeros(ComplexF64,N,N)
  for i=1:N,j=1:N
    x[i,j] = rand()
  end

  # FourierMatrix
  idx = CartesianIndices((N,N))[collect(1:N^2)]
  F = [ exp(-2*pi*im*((idx[j][1]-1)*(idx[k][1]-1)+(idx[j][2]-1)*(idx[k][2]-1))/N) for j=1:N^2, k=1:N^2 ]
  F_adj = F'

  # Operators
  tr = SimpleCartesianTrajectory(N,N)
  F_nfft = NFFTOp((N,N),tr,symmetrize=false)

  # test agains FourierOperators
  y = vec( ifftshift(reshape(F*vec(fftshift(x)),N,N)) )
  y_adj = vec( ifftshift(reshape(F_adj*vec(fftshift(x)),N,N)) )

  y_nfft = F_nfft*vec(x)
  y_adj_nfft = adjoint(F_nfft) * vec(x)

  @test (norm(y-y_nfft)/norm(y)) < 1e-2
  @test (norm(y_adj-y_adj_nfft)/norm(y_adj)) < 1e-2
end

# test FieldmapNFFTOp
function testFieldmapFT(N=16)
  # random image
  x = zeros(ComplexF64,N,N)
  for i=1:N,j=1:N
    x[i,j] = rand()
  end

  tr = SimpleCartesianTrajectory(N,N,0.0,0.01)
  times = readoutTimes(tr)
  nodes = kspaceNodes(tr)
  cmap = im*quadraticFieldmap(N,N)[:,:,1]

  # FourierMatrix
  idx = CartesianIndices((N,N))[collect(1:N^2)]
  F = [exp(-2*1im*pi*(nodes[1,k]*(idx[l][1]-size(x,1)/2-1)+nodes[2,k]*(idx[l][2]-size(x,2)/2-1))-cmap[idx[l][1],idx[l][2]]*times[k]) for k=1:size(nodes,2), l=1:length(x)]
  F_adj = F'

  # Operators
  F_nfft = FieldmapNFFTOp((N,N),tr,cmap,symmetrize=false)

  # test agains FourierOperators
  y = F*vec(x)
  y_adj = F_adj*vec(x)

  y_nfft = F_nfft*vec(x)
  y_adj_nfft = adjoint(F_nfft) * vec(x)

  @test (norm(y-y_nfft)/norm(y)) < 1e-2
  @test (norm(y_adj-y_adj_nfft)/norm(y_adj)) < 1e-2
end

function testOperators()
  @testset "Linear Operator" begin
    testFT()
    testFieldmapFT()
  end
end