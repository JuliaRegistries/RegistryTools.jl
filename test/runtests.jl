import RegistryTools
using Test: @testset, @test

@testset "RegistryTools" begin

include("regedit.jl")
include("compress.jl")

end
