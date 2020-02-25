using RegistryTools: DEFAULT_REGISTRY_URL,
    parse_registry,
    showsafe,
    registration_branch,
    get_registry
using LibGit2
using Pkg.TOML
using Pkg.Types: Project

using Test

const TEST_GITCONFIG = Dict(
    "user.name" => "RegistratorTests",
    "user.email" => "ci@juliacomputing.com",
)
const TEST_SIGNATURE = LibGit2.Signature(
    TEST_GITCONFIG["user.name"],
    TEST_GITCONFIG["user.email"],
)

@testset "RegistryTools" begin

@testset "Utilities" begin
    @testset "showsafe" begin
        @test string(showsafe(3)) == "3"
        @test string(showsafe(nothing)) == "nothing"
    end

    @testset "registration_branch" begin
        example = Project(Dict(
            "name" => "Example", "version" => "1.10.2",
            "uuid" => "698ec630-83b2-4a6d-81d4-a10176273030"
        ))
        @test registration_branch(example) == "registrator/example/698ec630/v1.10.2"
    end
end

@testset "RegistryCache" begin
    @testset "get_registry" begin
        mktempdir(@__DIR__) do temp_cache_dir
            # test when registry is not in the cache and not downloaded
            cache = RegistryTools.RegistryCache(temp_cache_dir)
            with(get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)) do repo
                @test LibGit2.path(repo) == replace(RegistryTools.path(cache, DEFAULT_REGISTRY_URL), '\\'=>'/')
                @test LibGit2.branch(repo) == "master"
                @test !LibGit2.isdirty(repo)
                @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL
            end

            # test when registry is in the cache but not downloaded
            registry_path = RegistryTools.path(cache, DEFAULT_REGISTRY_URL)
            rm(registry_path, recursive=true, force=true)
            @test !ispath(registry_path)
            with(get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)) do repo
                @test LibGit2.path(repo) == replace(RegistryTools.path(cache, DEFAULT_REGISTRY_URL), '\\'=>'/')
                @test LibGit2.branch(repo) == "master"
                @test !LibGit2.isdirty(repo)
                @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL

                # test when registry is in the cache, downloaded, but mutated
                orig_hash = LibGit2.GitHash()
                LibGit2.branch!(repo, "newbranch", force=true)
                LibGit2.remove!(repo, "Registry.toml")
                LibGit2.commit(
                    repo,
                    "Removing Registry.toml in Registrator tests";
                    author=TEST_SIGNATURE,
                    committer=TEST_SIGNATURE,
                )
                @test LibGit2.GitObject(repo, "HEAD") != LibGit2.GitObject(repo, "master")
                @test ispath(registry_path)
            end
            with(get_registry(DEFAULT_REGISTRY_URL, cache=cache, gitconfig=TEST_GITCONFIG)) do repo
                @test LibGit2.path(repo) == replace(RegistryTools.path(cache, DEFAULT_REGISTRY_URL), '\\'=>'/')
                @test LibGit2.branch(repo) == "master"
                @test !LibGit2.isdirty(repo)
                @test LibGit2.url(LibGit2.lookup_remote(repo, "origin")) == DEFAULT_REGISTRY_URL
            end
        end
    end
end

@testset "RegistryData" begin
    blank = RegistryTools.RegistryData("BlankRegistry", "d4e2f5cd-0f48-4704-9988-f1754e755b45")

    example = Project(Dict(
        "name" => "Example", "uuid" => "7876af07-990d-54b4-ab0e-23690620f79a"
    ))

    @testset "I/O" begin
        registry = """
            name = "General"
            uuid = "23338594-aafe-5451-b93e-139f81909106"
            repo = "https://github.com/JuliaRegistries/General.git"

            description = \"\"\"
            Official general Julia package registry where people can
            register any package they want without too much debate about
            naming and without enforced standards on documentation or
            testing. We nevertheless encourage documentation, testing and
            some amount of consideration when choosing package names.
            \"\"\"

            [packages]
            00701ae9-d1dc-5365-b64a-a3a3ebf5695e = { name = "BioAlignments", path = "B/BioAlignments" }
            00718b61-6157-5045-8849-3d4c4093d022 = { name = "Convertible", path = "C/Convertible" }
            0087ddc6-3964-5e57-817f-9937aefb0357 = { name = "MathOptInterfaceMosek", path = "M/MathOptInterfaceMosek" }
            """

        registry_data = parse_registry(IOBuffer(registry))
        @test registry_data isa RegistryTools.RegistryData
        written_registry = sprint(TOML.print, registry_data)
        written_registry_data = parse_registry(IOBuffer(written_registry))

        @test written_registry_data == registry_data
        @test written_registry == registry
    end

    @testset "Package Operations" begin
        registry_data = copy(blank)

        @test isempty(registry_data.packages)
        @test push!(registry_data, example) == registry_data
        @test length(registry_data.packages) == 1
        @test haskey(registry_data.packages, string(example.uuid))
        @test registry_data.packages[string(example.uuid)]["name"] == "Example"
        @test registry_data.packages[string(example.uuid)]["path"] == joinpath("E", "Example")
    end
end

@testset "check_version!" begin
    import RegistryTools: ReturnStatus, check_version!, haserror
    import Pkg.Types: Project
    function hascheck(status::ReturnStatus, check)
        return check in (c.id for c in status.triggered_checks)
    end

    for ver in [v"0.0.2", v"0.3.2", v"4.3.2"]
        status = ReturnStatus()
        check_version!(ver, VersionNumber[], status)
        @test hascheck(status, :not_standard_first_version)
        @test hascheck(status, :new_package_label)
        @test length(status.triggered_checks) == 2
        @test !haserror(status)
    end

    for ver in [v"0.0.1", v"0.1.0", v"1.0.0"]
        status = ReturnStatus()
        check_version!(ver, VersionNumber[], status)
        @test hascheck(status, :new_package_label)
        @test length(status.triggered_checks) == 1
        @test !haserror(status)
    end

    versions_list = [v"0.0.5", v"0.1.0", v"0.1.5", v"1.0.0"]
    let    # Less than least existing version
        ver = v"0.0.4"
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, :version_less_than_all_existing)
        @test length(status.triggered_checks) == 1
        @test !haserror(status)
    end

    let    # Existing version
        ver = v"0.0.5"
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, :version_exists)
        @test length(status.triggered_checks) == 1
        @test haserror(status)
    end

    # Non-existing version
    for (ver, type) in [(v"0.1.1", "patch"), (v"0.1.6", "patch"), (v"1.0.1", "patch"), (v"1.1.0", "minor")]
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, Symbol(type, "_release"))
        @test length(status.triggered_checks) == 1
        @test !haserror(status)
    end
    for (ver, type) in [(v"0.0.6", "patch"), (v"0.2.0", "minor"), (v"2.0.0", "major")]
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, Symbol(type, "_release"))
        @test hascheck(status, :breaking)
        @test length(status.triggered_checks) == 2
        @test !haserror(status)
    end

    # Skip a version
    for (ver, type) in [(v"0.1.2", "patch"), (v"0.1.7", "patch"), (v"1.0.2", "patch"), (v"1.2.0", "minor")]
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, Symbol(type, "_release"))
        @test hascheck(status, :version_skip)
        @test length(status.triggered_checks) == 2
        @test !haserror(status)
    end
    for (ver, type) in [(v"0.0.7", "patch"), (v"0.3.0", "minor"), (v"3.0.0", "major")]
        status = ReturnStatus()
        check_version!(ver, versions_list, status)
        @test hascheck(status, Symbol(type, "_release"))
        @test hascheck(status, :breaking)
        @test hascheck(status, :version_skip)
        @test length(status.triggered_checks) == 3
        @test !haserror(status)
    end
end

@testset "package_file" begin
    import RegistryTools: update_package_file
    mktempdir(@__DIR__) do temp_dir
        uuid = "698ec630-83b2-4a6d-81d4-a10176273030"
        pkg = Project(Dict("name" => "Example", "uuid" => uuid))
        repo = "https://example.com/example.git"
        update_package_file(pkg, repo, temp_dir)
        package_file = joinpath(temp_dir, "Package.toml")
        @test isfile(package_file)
        @test read(package_file, String) == """
                                            name = "Example"
                                            uuid = "$uuid"
                                            repo = "$repo"
                                            """
    end
end

@testset "versions_file" begin
    import RegistryTools: get_versions_file, update_versions_file, check_versions!
    mktempdir(@__DIR__) do temp_dir
        pkg = Project(version = v"1.0.0")
        tree_hash = repeat("0", 40)
        status = ReturnStatus()

        filename, data = get_versions_file(temp_dir)
        @test filename == joinpath(temp_dir, "Versions.toml")
        @test data isa Dict
        @test isempty(data)
        check_versions!(pkg, data, status)
        # No previous version registered, this version is fine.
        @test !haserror(status)

        update_versions_file(pkg, filename, data, tree_hash)

        _, data = get_versions_file(temp_dir)
        @test data isa Dict
        @test collect(keys(data)) == ["1.0.0"]
        @test data["1.0.0"] isa Dict
        @test collect(keys(data["1.0.0"])) == ["git-tree-sha1"]
        @test data["1.0.0"]["git-tree-sha1"] == tree_hash

        check_versions!(pkg, data, status)
        # This version was just registered, should be a complaint now.
        @test haserror(status)
    end
end

@testset "deps_file" begin
    import RegistryTools: update_deps_file
    mktempdir(@__DIR__) do temp_dir
        uuid = Base.UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40")
        deps = Dict("Test" => uuid)
        pkg = Project(version = v"1.0.0", deps = deps)
        update_versions_file(pkg, joinpath(temp_dir, "Versions.toml"),
                             Dict{String, Any}(), repeat("0", 40))
        update_deps_file(pkg, temp_dir)
        deps_file = joinpath(temp_dir, "Deps.toml")
        @test isfile(deps_file)
        @test read(deps_file, String) == """
                                         [1]
                                         Test = "$uuid"
                                         """
    end
end

@testset "compat_file" begin
    import RegistryTools: update_compat_file
    mktempdir(@__DIR__) do temp_dir
        compat = Dict("julia" => "1.3")
        pkg = Project(version = v"1.0.0", compat = compat)
        update_versions_file(pkg, joinpath(temp_dir, "Versions.toml"),
                             Dict{String, Any}(), repeat("0", 40))
        update_compat_file(pkg, temp_dir)
        compat_file = joinpath(temp_dir, "Compat.toml")
        @test isfile(compat_file)
        @test read(compat_file, String) == """
                                           [1]
                                           julia = "1.3.0-1"
                                           """
    end
end

@testset "registry updates" begin
    import RegistryTools: RegistryData, ReturnStatus, haserror,
                          write_registry, find_package_in_registry,
                          check_and_update_registry_files,
                          RegBranch, set_metadata!
    import Pkg.Types: read_project
    registry_update_tests =
        [
            # Add one simple package.
            (project_files = ["Example1"],
             status = Symbol[:new_package, :new_package_label],
             regbranch = (error = false, warning = false,
                          kind = "New package", labels = String["new package"]))

            # Increase patch revision.
            (project_files = ["Example1", "Example2"],
             status = Symbol[:new_version, :patch_release],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["patch_release"]))

            # Increase minor revision.
            (project_files = ["Example1", "Example2", "Example3"],
             status = Symbol[:new_version, :minor_release],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["minor_release"]))

            # Increase major revision.
            (project_files = ["Example1", "Example4"],
             status = Symbol[:new_version, :major_release, :breaking],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["major_release", "BREAKING"]))

            # Adding a minor revision after next major revision has
            # been registered.
            (project_files = ["Example1", "Example4", "Example3"],
             status = Symbol[:new_version, :minor_release],
             regbranch = (error = false, warning = false,
                          kind = "New version",
                          labels = String["minor_release"]))

            # Adding a revision that comes before all registered versions.
            (project_files = ["Example2", "Example4", "Example3", "Example1"],
             status = Symbol[:new_version, :version_less_than_all_existing],
             regbranch = (error = true, warning = false,
                          kind = "New version", labels = String[]))

            # Non-standard first version.
            (project_files = ["Example2"],
             status = Symbol[:new_package, :new_package_label,
                             :not_standard_first_version],
             regbranch = (error = false, warning = true,
                          kind = "New package", labels = String["new package"]))

            # Version zero.
            (project_files = ["Example5"],
             status = Symbol[:new_package, :new_package_label, :version_zero,
                             :not_standard_first_version],
             regbranch = (error = true, warning = true,
                          kind = "New package", labels = String["new package"]))

            # Skipped versions.
            (project_files = ["Example1", "Example6"],
             status = Symbol[:new_version, :minor_release, :version_skip],
             regbranch = (error = false, warning = true,
                          kind = "New version",
                          labels = String["minor_release"]))

            # Adding an existing version.
            (project_files = ["Example1", "Example1"],
             status = Symbol[:new_version, :version_exists],
             regbranch = (error = true, warning = false,
                          kind = "New version",
                          labels = String[]))

            # Changing name.
            (project_files = ["Example1", "Example7"],
             status = Symbol[:change_package_name],
             regbranch = (error = true, warning = false,
                          kind = "",
                          labels = String[]))

            # Changing uuid.
            (project_files = ["Example1", "Example8"],
             status = Symbol[:change_package_uuid],
             regbranch = (error = true, warning = false,
                          kind = "",
                          labels = String[]))

            # Incorrect stdlib uuid.
            (project_files = ["Example9"],
             status = Symbol[:new_package, :new_package_label,
                             :wrong_stdlib_uuid],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Dependency on itself.
            (project_files = ["Example10"],
             status = Symbol[:new_package, :new_package_label,
                             :package_self_dep],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Incorrect spelling of an stdlib.
            # (Arguably this should complain differently since the
            # UUID is known.)
            (project_files = ["Example11"],
             status = Symbol[:new_package, :new_package_label,
                             :dependency_not_found],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Missing dependency.
            (project_files = ["Example12"],
             status = Symbol[:new_package, :new_package_label,
                             :dependency_not_found],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Dependency no longer missing.
            (project_files = ["Dep1", "Example12"],
             status = Symbol[:new_package, :new_package_label],
             regbranch = (error = false, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Dependency not missing but incorrectly spelled.
            (project_files = ["Dep1", "Example13"],
             status = Symbol[:new_package, :new_package_label, :name_mismatch],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Compatibility with Julia before 0.7.
            (project_files = ["Example14"],
             status = Symbol[:new_package, :new_package_label,
                             :julia_before_07_in_compat],
             regbranch = (error = true, warning = false,
                          kind = "New package",
                          labels = String["new package"]))

            # Change package repo.
            (project_files = ["Example1", "Example2"],
             modify_package_repo = "Example2",
             status = Symbol[:new_version, :patch_release, :change_package_url],
             regbranch = (error = true, warning = false,
                          kind = "New version",
                          labels = String["patch_release"]))
        ]


    mktempdir(@__DIR__) do temp_dir
        registry_path = joinpath(temp_dir, "registry")
        registry_file = joinpath(registry_path, "Registry.toml")
        projects_path = joinpath(@__DIR__, "project_files")
        registry_deps_paths = String[]
        tree_hash = repeat("0", 40)
        for test_data in registry_update_tests
            # Clean up from previous iteration.
            isdir(registry_path) && rm(registry_path, recursive = true)
            mkpath(registry_path)
            # Start with an empty registry.
            registry_data = RegistryData("TestRegistry",
                                         "d4e2f5cd-0f48-4704-9988-f1754e755b45")
            write_registry(registry_file, registry_data)
            local status, regbr
            # Register some packages.
            for project in test_data.project_files
                project_file = joinpath(projects_path, "$(project).toml")
                pkg = read_project(project_file)
                # Create status object.
                status = ReturnStatus()
                regbr = RegBranch(pkg, "")
                package_repo = string("http://example.com/$(pkg.name).git")
                if get(test_data, :modify_package_repo, "") == project
                    package_repo = string("http://example.org/$(pkg.name).git")
                end
                check_and_update_registry_files(pkg, package_repo, tree_hash,
                                                registry_path,
                                                registry_deps_paths, status)
                haserror(status) && break
            end
            # Test the return status of the last package registration.
            @test sort([check.id for check in status.triggered_checks]) == sort(test_data.status)
            set_metadata!(regbr, status)
            @test haskey(regbr.metadata, "error") == test_data.regbranch.error
            @test haskey(regbr.metadata, "warning") == test_data.regbranch.warning
            @test get(regbr.metadata, "kind", "") == test_data.regbranch.kind
            @test sort(get(regbr.metadata, "labels", String[])) == sort(test_data.regbranch.labels)
        end
    end
end

end
