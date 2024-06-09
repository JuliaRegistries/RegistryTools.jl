import RegistryTools
using Test: @testset, @test
import Pkg

@testset "RegistryTools" begin

include("regedit.jl")
include("compress.jl")

# ExplicitImports does not support as old Julia versions as RegistryTools does.
# Change this to a regular test dependency when it becomes possible, i.e.
# when pre-1.7 support is dropped.
if VERSION >= v"1.7"
Pkg.add(name = "ExplicitImports", uuid = "7d51a73a-1435-4ff3-83d9-f097790105c7", preserve=Pkg.PRESERVE_ALL)
using ExplicitImports: check_no_implicit_imports, check_no_stale_explicit_imports
@testset "ExplicitImports" begin
    @test isnothing(check_no_implicit_imports(RegistryTools))
    @test isnothing(check_no_stale_explicit_imports(RegistryTools))
end
end

end
