using Pkg
using RegistryTools.Compress: compress_versions, load, compress

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

@testset "Compress.load" begin
    mktempdir(@__DIR__) do temp_dir
        versions = [v"1.0.0", v"1.1.0", v"1.2.0", v"1.3.0"]
        compat_file = joinpath(temp_dir, "Compat.toml")
        good_compat = """
            ["1-1.1"]
            julia = "1"

            ["1.2-1"]
            julia = "1.3.0-1"
            """
        write(compat_file, good_compat)
        compat = load(compat_file, versions)
        @test compat[v"1.0.0"] == Dict("julia" => "1")
        @test compat[v"1.1.0"] == Dict("julia" => "1")
        @test compat[v"1.2.0"] == Dict("julia" => "1.3.0-1")
        @test compat[v"1.3.0"] == Dict("julia" => "1.3.0-1")

        # Overlapping ranges.
        bad_compat = """
            ["1-1.1.2"]
            julia = "1"

            ["1.1.0-1"]
            julia = "1.3.0-1"
            """
        write(compat_file, bad_compat)
        @test_throws ErrorException load(compat_file, versions)
    end
end

@testset "issue#46: compress with mixed input data" begin
    pkglibdl_str = Dict("Pkg" => "44cfe95a-1eb2-52ea-b672-e2afdf69b78f",
                        "Libdl" => "8f399da3-3557-5675-b5ff-fb832c97cbdb")
    pkglibdl_uuid = Dict{String, Base.UUID}(k => Base.UUID(v) for (k, v) in pkglibdl_str)
    uncompressed = Dict{VersionNumber, Dict{Any, Any}}(
        v"0.21.1+0" => pkglibdl_str,
        v"0.22.0+0" => pkglibdl_str,
        v"0.22.1+0" => pkglibdl_uuid
        )
    versions = VersionNumber[ v"0.21.1+0", v"0.22.0+0"]
    compressed = compress("/dev/null", uncompressed, versions)
    @test compressed == Dict{String,Any}("0" => pkglibdl_str)
end
