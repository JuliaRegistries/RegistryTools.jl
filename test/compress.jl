using Pkg
using RegistryTools.Compress: compress_versions

@testset "compress_versions()" begin
    # Test exact version matching
    vs = [v"1.1.0", v"1.1.1", v"1.1.2"]
    @test compress_versions(vs, [vs[2]]) == Pkg.Types.VersionSpec("1.1.1")

    # Test holes
    vs = [v"1.1.0", v"1.1.1", v"1.1.4"]
    @test compress_versions(vs, [vs[2]]) == Pkg.Types.VersionSpec("1.1.1")

    # Test patch variation with length(subset) > 1
    vs = [v"1.1.0", v"1.1.1", v"1.1.2", v"1.1.3", v"1.2.0"]
    @test compress_versions(vs, [vs[2], vs[3]]) == Pkg.Types.VersionSpec("1.1.1-1.1.2")

    # Test minor variation
    vs = [v"1.1.0", v"1.1.1", v"1.2.0"]
    @test compress_versions(vs, [vs[2]]) == Pkg.Types.VersionSpec("1.1.1-1.1")

    # Test major variation
    vs = [v"1.1.0", v"1.1.1", v"1.2.0", v"2.0.0"]
    @test compress_versions(vs, [vs[2], vs[3]]) == Pkg.Types.VersionSpec("1.1.1-1")

    # Test build numbers and prerelease values are ignored
    vs = [v"1.1.0-alpha", v"1.1.0+0", v"1.1.0+1"]
    @test compress_versions(vs, [vs[2]]) == Pkg.Types.VersionSpec("1")
end
 
