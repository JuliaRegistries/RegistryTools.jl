"""
Given a remote repo URL and a git tree spec, get a `Project` object
for the project file in that tree and a hash string for the tree.
"""
# function get_project(remote_url::AbstractString, tree_spec::AbstractString)
#     # TODO?: use raw file downloads for GitHub/GitLab
#     mktempdir(mkpath("packages")) do tmp
#         # bare clone the package repo
#         @debug("bare clone the package repo")
#         repo = LibGit2.clone(remote_url, joinpath(tmp, "repo"), isbare=true)
#         tree = try
#             LibGit2.GitObject(repo, tree_spec)
#         catch err
#             err isa LibGit2.GitError && err.code == LibGit2.Error.ENOTFOUND || rethrow(err)
#             error("$remote_url: git object $(repr(tree_spec)) could not be found")
#         end
#         tree isa LibGit2.GitTree || (tree = LibGit2.peel(LibGit2.GitTree, tree))
#
#         # check out the requested tree
#         @debug("check out the requested tree")
#         tree_path = abspath(tmp, "tree")
#         GC.@preserve tree_path begin
#             opts = LibGit2.CheckoutOptions(
#                 checkout_strategy = LibGit2.Consts.CHECKOUT_FORCE,
#                 target_directory = Base.unsafe_convert(Cstring, tree_path)
#             )
#             LibGit2.checkout_tree(repo, tree, options=opts)
#         end
#
#         # look for a project file in the tree
#         @debug("look for a project file in the tree")
#         project_file = Pkg.Types.projectfile_path(tree_path)
#         project_file !== nothing && isfile(project_file) ||
#             error("$remote_url: git tree $(repr(tree_spec)) has no project file")
#
#         # parse the project file
#         @debug("parse the project file")
#         project = Pkg.Types.read_project(project_file)
#         project.name === nothing &&
#             error("$remote_url $(repr(tree_spec)): package has no name")
#         project.uuid === nothing &&
#             error("$remote_url $(repr(tree_spec)): package has no UUID")
#         project.version === nothing &&
#             error("$remote_url $(repr(tree_spec)): package has no version")
#
#         return project, string(LibGit2.GitHash(tree))
#     end
# end

const PKG_HAS_WEAK = hasfield(Pkg.Types.Project, :_deps_weak)

function getdeps(pkg)
    if PKG_HAS_WEAK
        return merge(pkg.deps, pkg._deps_weak)
    end
    return pkg.deps
end

# These can compromise the integrity of the registry and cannot be
# opted out of.
const mandatory_errors = [:version_exists,
                          :change_package_name,  # not implemented
                          :change_package_uuid,  # not allowed
                          :package_self_dep,
                          :name_mismatch,
                          :wrong_stdlib_uuid,
                          :package_url_missing
                          ]

# These are considered errors by Registrator and are default for the
# `register` function. The caller can override this selection.
const registrator_errors = [:version_zero,
                            :version_less_than_all_existing,
                            :change_package_url,
                            :dependency_not_found,
                            :julia_before_07_in_compat,
                            :invalid_compat,
                            :unexpected_registration_error
                            ]

mutable struct ReturnStatus
    triggered_checks::Vector{NamedTuple}
    errors::Set{Symbol}
    error_found::Bool
end

function ReturnStatus(errors::Vector{Symbol} = Symbol[])
    ReturnStatus(NamedTuple[], union!(Set(mandatory_errors), errors), false)
end

function add!(status::ReturnStatus, check::Symbol,
              data::Union{Nothing, NamedTuple}=nothing)
    if isnothing(data)
        push!(status.triggered_checks, (id = check,))
    else
        push!(status.triggered_checks, merge((id = check,), data))
    end
    status.error_found |= check in status.errors
end

haserror(status::ReturnStatus) = status.error_found

struct RegBranch
    name::String
    version::VersionNumber
    branch::String

    metadata::Dict{String, Any} # "error", "warning", kind etc.

    function RegBranch(pkg::Pkg.Types.Project, branch::AbstractString)
        new(pkg.name, pkg.version, branch, Dict{String,Any}())
    end
end

function add_label!(regbr::RegBranch, label)
    if !haskey(regbr.metadata, "labels")
        regbr.metadata["labels"] = String[]
    end
    pushfirst!(regbr.metadata["labels"], label)
end

# error in regbr.metadata["errors"]
# warning in regbr.metadata["warning"]
# version labels for the PR in in regbr.metadata["labels"]
function set_metadata!(regbr::RegBranch, status::ReturnStatus)
    empty!(regbr.metadata)
    for triggered_check in reverse(status.triggered_checks)
        check = triggered_check.id
        data = triggered_check
        complaint = check in status.errors ? "error" : "warning"
        if check == :version_zero
            regbr.metadata[complaint] = "Package version must be greater than 0.0.0"
        elseif check == :new_package_label
            add_label!(regbr, "new package")
        elseif check == :not_standard_first_version
            regbr.metadata[complaint] =
                """This looks like a new registration that registers version $(data.version).
                Ideally, you should register an initial release with 0.0.1, 0.1.0 or 1.0.0 version numbers"""
        elseif check == :version_less_than_all_existing
            regbr.metadata[complaint] = "Version $(data.version) less than least existing version $(data.least)"
        elseif check == :version_exists
            regbr.metadata[complaint] = "Version $(data.version) already exists"
        elseif check == :major_release
            add_label!(regbr, "major release")
        elseif check == :minor_release
            add_label!(regbr, "minor release")
        elseif check == :patch_release
            add_label!(regbr, "patch release")
        elseif check == :breaking
            add_label!(regbr, "BREAKING")
        elseif check == :version_skip
            regbr.metadata[complaint] = "Version $(data.version) skips over $(data.next)"
        elseif check == :change_package_name
            regbr.metadata[complaint] = "Changing package names not supported yet"
        elseif check == :change_package_url
            regbr.metadata[complaint] = "Changing package repo URL not allowed, please submit a pull request with the URL change to the target registry and retry."
        elseif check == :new_version
            regbr.metadata["kind"] = "New version"
        elseif check == :new_package
            regbr.metadata["kind"] = "New package"
        elseif check == :change_package_uuid
            regbr.metadata[complaint] = "Changing UUIDs is not allowed"
        elseif check == :package_self_dep
            regbr.metadata[complaint] = "Package $(data.name) mentions itself in `[deps]`"
        elseif check == :name_mismatch
            regbr.metadata[complaint] = "Error in (Julia)Project.toml: UUID $(data.uuid) refers to package '$(data.reg_name)' in registry but Project.toml has '$(data.project_name)'"
        elseif check == :wrong_stdlib_uuid
            regbr.metadata[complaint] = "Error in (Julia)Project.toml: UUID $(data.project_uuid) for package $(data.name) should be $(data.stdlib_uuid)"
        elseif check == :dependency_not_found
            regbr.metadata[complaint] = "Error in (Julia)Project.toml: Package '$(data.name)' with UUID: $(data.uuid) not found in registry or stdlib"
        elseif check == :julia_before_07_in_compat
            regbr.metadata[complaint] = "Julia version < 0.7 not allowed in `[compat]`"
        elseif check == :invalid_compat
            regbr.metadata[complaint] = "Following packages are mentioned in `[compat]` but not found in `[deps]` or `[extras]`:\n" * join(data.invalid_compats, "\n")
        elseif check == :package_url_missing
            regbr.metadata[complaint] = "No repo URL provided for a new package"
        elseif check == :unexpected_registration_error
            regbr.metadata[complaint] = "Unexpected error in registration"
        end
    end
    return regbr
end

get_backtrace(ex) = sprint(Base.showerror, ex, catch_backtrace())

function write_registry(registry_path::AbstractString, reg::RegistryData)
    open(registry_path, "w") do io
        TOML.print(io, reg)
    end
end

function check_version!(version::VersionNumber, existing::Vector{VersionNumber},
                        status::ReturnStatus)
    if version == v"0"
        add!(status, :version_zero)
        haserror(status) && return
    end

    @assert issorted(existing)
    if isempty(existing)
        add!(status, :new_package_label)
        if !(version in [v"0.0.1", v"0.1", v"1"])
            add!(status, :not_standard_first_version, (version = version,))
        end
    else
        idx = searchsortedlast(existing, version)
        if idx <= 0
            add!(status, :version_less_than_all_existing,
                 (version = version, least = first(existing)))
            return
        end

        previous = existing[idx]
        if version == previous
            add!(status, :version_exists, (version = version,))
            haserror(status) && return
        end
        if version.major != previous.major
            add!(status, :major_release)
            add!(status, :breaking)
            next = VersionNumber(previous.major + 1, 0, 0)
        elseif version.minor != previous.minor
            add!(status, :minor_release)
            if version.major == 0
                add!(status, :breaking)
            end
            next = VersionNumber(previous.major, previous.minor + 1, 0)
        else
            add!(status, :patch_release)
            if version.major == version.minor == 0
                add!(status, :breaking)
            end
            next = VersionNumber(previous.major, previous.minor, previous.patch + 1)
        end
        if version > next
            add!(status, :version_skip, (version = version, next = next))
        end
    end

    return
end

findpackageerror!(name::AbstractString, uuid::Base.UUID,
                  regdata::Array{RegistryData}, status::ReturnStatus) =
    findpackageerror!(name, string(uuid), regdata, status)

# Check that `uuid` is found in `regdata` OR `name` is found in
# `BUILTIN_PKGS` (i.e. stdlibs). In the former case, check that `name`
# matches the found uuid and in the latter case that `uuid` matches
# the found name.
function findpackageerror!(name::AbstractString, uuid::AbstractString,
                           regdata::Array{RegistryData}, status::ReturnStatus)
    for registry_data in regdata
        if haskey(registry_data.packages, uuid)
            name_in_reg = registry_data.packages[uuid]["name"]
            if name_in_reg != name
                @debug(:name_mismatch)
                add!(status, :name_mismatch,
                     (uuid = uuid, reg_name = name_in_reg, project_name = name))
            end
            return
        end
    end

    if haskey(BUILTIN_PKGS, name)
        if BUILTIN_PKGS[name] != uuid
            @debug(:wrong_stdlib_uuid)
            add!(status, :wrong_stdlib_uuid,
                 (project_uuid = uuid, name = name,
                  stdlib_uuid = BUILTIN_PKGS[name]))
        end
    else
        @debug(:dependency_not_found)
        add!(status, :dependency_not_found, (name = name, uuid = uuid))
    end

    return
end

import Pkg.Types: VersionRange, VersionBound, VersionSpec

function versionrange(lo::VersionBound, hi::VersionBound)
    lo.t == hi.t && (lo = hi)
    return VersionRange(lo, hi)
end

function find_package_in_registry(pkg::Pkg.Types.Project,
                                  registry_file::AbstractString,
                                  registry_path::AbstractString,
                                  registry_data::RegistryData,
                                  status::ReturnStatus)
    uuid = string(pkg.uuid)
    if haskey(registry_data.packages, uuid)
        package_data = registry_data.packages[uuid]
        if package_data["name"] != pkg.name
            err = :change_package_name
            @debug(err)
            add!(status, err)
            haserror(status) && return nothing
        end
        package_path = joinpath(registry_path, package_data["path"])
        add!(status, :new_version)
    else
        @debug("Package with UUID: $uuid not found in registry, checking if UUID was changed")
        for (k, v) in registry_data.packages
            if v["name"] == pkg.name
                err = :change_package_uuid
                @debug(err)
                add!(status, err)
                haserror(status) && return nothing
            end
        end

        @debug("Creating directory for new package $(pkg.name)")
        package_path = joinpath(registry_path, package_relpath(pkg))
        mkpath(package_path)

        @debug("Adding package UUID to registry")
        push!(registry_data, pkg)
        write_registry(registry_file, registry_data)
        add!(status, :new_package)
    end

    return package_path
end

# If `package_repo` is an empty string, replace it with what is
# already stored in Package.toml.
function check_package!(package_repo::AbstractString,
                        package_path::AbstractString,
                        status::ReturnStatus)
    package_file = joinpath(package_path, "Package.toml")
    # If this is a registration of a new package, the package file has
    # not been created yet.
    if isfile(package_file)
        repo = TOML.parsefile(package_file)["repo"]
        if isempty(package_repo)
            package_repo = repo
        elseif repo != package_repo
            err = :change_package_url
            @debug(err)
            add!(status, err)
        end
    elseif isempty(package_repo)
        add!(status, :package_url_missing)
    end

    return package_repo
end

function update_package_file(pkg::Pkg.Types.Project,
                             package_repo::AbstractString,
                             subdir::AbstractString,
                             package_path::AbstractString)
    package_info = Dict{String,String}(
                        "name" => pkg.name,
                        "uuid" => string(pkg.uuid),
                        "repo" => package_repo)
    if !isempty(subdir)
        package_info["subdir"] = subdir
    end
    package_file = joinpath(package_path, "Package.toml")
    open(package_file, "w") do io
        TOML.print(io, package_info; sorted=true,
            by = x -> x == "name" ? 1 : x == "uuid" ? 2 : x == "repo" ? 3 : 4)
    end
    nothing
end

function get_versions_file(package_path::AbstractString)
    filename = joinpath(package_path, "Versions.toml")
    data = isfile(filename) ? TOML.parsefile(filename) : Dict{String, Any}()
    return filename, data
end

function check_versions!(pkg::Pkg.Types.Project,
                         versions_data::Dict{String, Any},
                         status::ReturnStatus)
    versions = sort!([VersionNumber(v) for v in keys(versions_data)])
    check_version!(pkg.version, versions, status)
    return versions
end

function update_versions_file(pkg::Pkg.Types.Project,
                              versions_file::AbstractString,
                              versions_data::Dict{String, Any},
                              tree_hash::AbstractString)
    version_info = Dict{String, Any}("git-tree-sha1" => string(tree_hash))
    versions_data[string(pkg.version)] = version_info

    open(versions_file, "w") do io
        # TOML.print with sorted=true sorts recursively
        # so this by function needs to handle the outer dict
        # with version number keys, and the inner dict with
        # git-tree-sha1, yanked, etc as keys.
        function by(x)
            if occursin(Base.VERSION_REGEX, x)
                return VersionNumber(x)
            else
                if x == "git-tree-sha1"
                    return 1
                elseif x == "yanked"
                    return 2
                else
                    return 3
                end
            end
        end
        TOML.print(io, versions_data; sorted=true, by=by)
    end
end

function check_deps!(pkg::Pkg.Types.Project,
                     regdata::Vector{RegistryData},
                     status::ReturnStatus)
    depses = [getdeps(pkg)]
    PKG_HAS_WEAK && push!(depses, pkg.weakdeps)
    for deps in depses
        if pkg.name in keys(deps)
            err = :package_self_dep
            @debug(err)
            add!(status, err, (name = pkg.name,))
            haserror(status) && return
        end

        @debug("Verifying package name and uuid in deps/weakdeps")
        for (name, uuid) in deps
            findpackageerror!(name, uuid, regdata, status)
        end
    end
end

# Note that Compress.load should load with respect to Versions.toml
# before update and Compress.save should save with respect to
# Versions.toml after update. This is handled with the `old_versions'
# argument and the assumption that Versions.toml has been updated with
# the new version before calling this function.
function update_deps_file(pkg::Pkg.Types.Project,
                          package_path::AbstractString,
                          old_versions::Vector{VersionNumber})
    file_depses = [("Deps.toml", getdeps(pkg))]
    PKG_HAS_WEAK && push!(file_depses, ("WeakDeps.toml", pkg.weakdeps)) 
    for (file, deps) in file_depses
        deps_file = joinpath(package_path, file)
        if isfile(deps_file)
            deps_data = Compress.load(deps_file, old_versions)
        else
            deps_data = Dict()
        end

        deps_data[pkg.version] = deps
        Compress.save(deps_file, deps_data)
    end
end

function check_compat!(pkg::Pkg.Types.Project,
                       regdata::Vector{RegistryData},
                       regpaths::Vector{String},
                       status::ReturnStatus)
    if haskey(pkg.compat, "julia")
        if Base.VERSION >= v"1.7-"
            ver = pkg.compat["julia"].val
        else 
            ver = Pkg.Types.semver_spec(pkg.compat["julia"])
        end
        if any(map(x -> !isempty(intersect(Pkg.Types.VersionRange("0-0.6"), x)), ver.ranges))
            err = :julia_before_07_in_compat
            @debug(err)
            add!(status, err)
            haserror(status) && return
        end
    end

    # Note: These checks are meaningless for Julia >= 1.2 since
    # Pkg.Types.load_project will give an error if there are compat
    # entries not mentioned in deps, nor in extras.
    invalid_compats = []
    for name in keys(pkg.compat)
        indeps = haskey(getdeps(pkg), name)
        inextras = haskey(pkg.extras, name)
        inweaks = PKG_HAS_WEAK ? haskey(pkg.weakdeps, name) : false
        if !(indeps || inextras || inweaks || name == "julia")
            push!(invalid_compats, name)
        end
    end
    if !isempty(invalid_compats)
        err = :invalid_compat
        @debug(err)
        add!(status, err, (invalid_compats = invalid_compats,))
        haserror(status) && return
    end

    # Note: `findpackageerror` has already been run for all entries in
    # deps so doing it again for the intersection of compat and deps
    # is redundant. Doing it for the intersection of compat and extras
    # is meaningful but it is unclear why not just do it for all
    # entries in extras at the same time it's done for all entries in
    # deps. Alternatively it can be skipped entirely since nothing
    # that is in extras only will be stored in the registry files
    # anyway.
    for name in keys(pkg.compat)
        if name != "julia"
            indeps = haskey(getdeps(pkg), name)
            inextras = haskey(pkg.extras, name)

            if indeps
                uuidofdep = string(getdeps(pkg)[name])
                findpackageerror!(name, uuidofdep, regdata, status)
            elseif inextras
                uuidofdep = string(pkg.extras[name])
                findpackageerror!(name, uuidofdep, regdata, status)
            end

            haserror(status) && return
        end
    end

    return
end

# See the comments for `update_deps_file` for the rationale for the
# `old_versions` argument.
function update_compat_file(pkg::Pkg.Types.Project,
                            package_path::AbstractString,
                            old_versions::Vector{VersionNumber})
    @debug("update package data: compat file")
    
    file_depses = [("Compat.toml", getdeps(pkg))]
    PKG_HAS_WEAK && push!(file_depses, ("WeakCompat.toml", pkg.weakdeps)) 
    for (file, deps) in file_depses
        compat_file = joinpath(package_path, file)
        if isfile(compat_file)
            compat_data = Compress.load(compat_file, old_versions)
        else
            compat_data = Dict()
        end

        d = Dict()
        for (name, version) in pkg.compat
            if !haskey(deps, name) && name != "julia"
                @debug("$name is a not in relevant dependency list; omitting from Compat.toml")
                continue
            end

            if Base.VERSION >= v"1.7-"
                spec = version.val
            else
                spec = Pkg.Types.semver_spec(version)
            end
            # The call to `map(versionrange, )` can be removed
            # once Pkg is updated to a version including
            # https://github.com/JuliaLang/Pkg.jl/pull/1181
            # and support for older versions is dropped.
            ranges = map(r->versionrange(r.lower, r.upper), spec.ranges)
            ranges = VersionSpec(ranges).ranges # this combines joinable ranges
            d[name] = length(ranges) == 1 ? string(ranges[1]) : map(string, ranges)
        end

        compat_data[pkg.version] = d
        Compress.save(compat_file, compat_data)
    end
end

function get_registrator_tree_sha()
    # If Registrator is in the manifest, return its tree-sha.
    # Otherwise return the tree-sha for RegistryTools.
    manifest = Pkg.Types.Context().env.manifest
    registrator_uuid = Base.UUID("4418983a-e44d-11e8-3aec-9789530b3b3e")
    registry_tools_uuid = Base.UUID("d1eb7eb1-105f-429d-abf5-b0f65cb9e2c4")
    reg_pkg = get(manifest, registrator_uuid,
                  get(manifest, registry_tools_uuid, nothing))
    if reg_pkg !== nothing && VERSION >= v"1.2.0-rc1" && reg_pkg.tree_hash !== nothing
        return reg_pkg.tree_hash
    end
    return "unknown"
end

function check_and_update_registry_files(pkg, package_repo, tree_hash,
                                         registry_path, registry_deps_paths,
                                         status; subdir = "")
    # find package in registry
    @debug("find package in registry")
    registry_file = joinpath(registry_path, "Registry.toml")
    registry_data = parse_registry(registry_file)
    package_path = find_package_in_registry(pkg, registry_file, registry_path,
                                            registry_data, status)
    haserror(status) && return

    # update package data: package file
    @debug("update package data: package file")
    package_repo = check_package!(package_repo, package_path, status)
    haserror(status) && return
    update_package_file(pkg, package_repo, subdir, package_path)

    # update package data: versions file
    @debug("update package data: versions file")
    versions_file, versions_data = get_versions_file(package_path)
    old_versions = check_versions!(pkg, versions_data, status)
    haserror(status) && return
    update_versions_file(pkg, versions_file, versions_data, tree_hash)

    # update package data: deps file
    @debug("update package data: deps file")
    registry_deps_data = map(registry_deps_paths) do registry_path
        parse_registry(joinpath(registry_path, "Registry.toml"))
    end
    regdata = [registry_data; registry_deps_data]
    check_deps!(pkg, regdata, status)
    haserror(status) && return
    update_deps_file(pkg, package_path, old_versions)

    # update package data: compat file
    @debug("check compat section")
    regpaths = [registry_path; registry_deps_paths]
    check_compat!(pkg, regdata, regpaths, status)
    haserror(status) && return
    update_compat_file(pkg, package_path, old_versions)
end

"""
    register(package_repo, pkg, tree_hash; registry, registry_fork, registry_deps, push, gitconfig)

Register the package at `package_repo` / `tree_hash` in `registry`.
Returns a `RegEdit.RegBranch` which contains information about the registration and/or any
errors or warnings that occurred.

# Arguments

* `package_repo::AbstractString`: The git repository URL for the package to be registered. If empty, keep the stored repository URL.
* `pkg::Pkg.Types.Project`: the parsed (Julia)Project.toml file for the package to be registered
* `tree_hash::AbstractString`: the tree hash (not commit hash) of the package revision to be registered

# Keyword Arguments

* `registry::AbstractString="$DEFAULT_REGISTRY_URL"`: the git repository URL for the registry
* `registry_fork::AbstractString=registry: the git repository URL for a fork of the registry
* `registry_deps::Vector{String}=[]`: the git repository URLs for any registries containing
    packages depended on by `pkg`
* `subdir::AbstractString=""`: path to package within `package_repo`
* `push::Bool=false`: whether to push a registration branch to `registry` for consideration
* `gitconfig::Dict=Dict()`: dictionary of configuration options for the `git` command
"""
function register(
    package_repo::AbstractString, pkg::Pkg.Types.Project, tree_hash::AbstractString;
    registry::AbstractString = DEFAULT_REGISTRY_URL,
    registry_fork::AbstractString = registry,
    registry_deps::Vector{<:AbstractString} = AbstractString[],
    subdir::AbstractString = "",
    checks_triggering_error = registrator_errors,
    push::Bool = false,
    force_reset::Bool = true,
    branch::AbstractString = registration_branch(pkg; url=package_repo),
    cache::RegistryCache=REGISTRY_CACHE,
    gitconfig::Dict = Dict()
)
    # get info from package registry
    @debug("get info from package registry")
    if !isempty(package_repo)
        package_repo = GitTools.normalize_url(package_repo)
    end

    # return object
    regbr = RegBranch(pkg, branch)

    # status object
    status = ReturnStatus(checks_triggering_error)

    # get up-to-date clone of registry
    @debug("get up-to-date clone of registry")
    registry = GitTools.normalize_url(registry)
    registry_repo = get_registry(registry; gitconfig=gitconfig, force_reset=force_reset, cache=cache)
    registry_path = LibGit2.path(registry_repo)

    isempty(registry_deps) || @debug("get up-to-date clones of registry dependencies")
    registry_deps_paths = map(registry_deps) do registry
        LibGit2.path(get_registry(GitTools.normalize_url(registry); gitconfig=gitconfig, force_reset=force_reset, cache=cache))
    end

    try
        # branch registry repo
        @debug("branch registry repo")
        git = gitcmd(registry_path, gitconfig)
        registry_defbranch = get_registry_default_branch(git)
        run(pipeline(`$git checkout -f $registry_defbranch`; stdout=devnull))
        if branch != registry_defbranch
            run(pipeline(`$git branch -f $branch`; stdout=devnull))
            run(pipeline(`$git checkout -f $branch`; stdout=devnull))
        end

        check_and_update_registry_files(pkg, package_repo, tree_hash,
                                        registry_path, registry_deps_paths,
                                        status, subdir = subdir)
        haserror(status) && return set_metadata!(regbr, status)

        regtreesha = get_registrator_tree_sha()
        # To get "kind" information. Otherwise redundant to do it here.
        set_metadata!(regbr, status)

        # commit changes
        @debug("commit changes")
        message = """
        $(regbr.metadata["kind"]): $(pkg.name) v$(pkg.version)

        UUID: $(pkg.uuid)
        Repo: $(package_repo)
        Tree: $(string(tree_hash))

        Registrator tree SHA: $(regtreesha)
        """
        registry_file = joinpath(registry_path, "Registry.toml")
        package_path = joinpath(registry_path, package_relpath(pkg))
        run(pipeline(`$git add -- $package_path`; stdout=devnull))
        run(pipeline(`$git add -- $registry_file`; stdout=devnull))
        run(pipeline(`$git commit -m $message`; stdout=devnull))

        # push -f branch to remote
        if push
            @debug("push -f branch to remote")
            run(pipeline(`$git remote set-url --push origin $registry_fork`))
            run(pipeline(`$git push -f -u origin $branch`; stdout=devnull))
        else
            @debug("skipping git push")
        end
    catch ex
        @error("Unexpected error while registering", stacktrace=get_backtrace(ex))
        add!(status, :unexpected_registration_error)
        @debug("cleaning up possibly inconsistent registry", registry_path=showsafe(registry_path))
        rm(registry_path; recursive=true, force=true)
    end
    return set_metadata!(regbr, status)
end

struct RegisterParams
    package_repo::String
    pkg::Pkg.Types.Project
    tree_sha::String
    registry::String
    registry_fork::String
    registry_deps::Vector{<:String}
    subdir::String
    push::Bool
    gitconfig::Dict

    function RegisterParams(package_repo::AbstractString,
                            pkg::Pkg.Types.Project,
                            tree_sha::AbstractString;
                            registry::AbstractString=DEFAULT_REGISTRY_URL,
                            registry_fork::AbstractString=registry,
                            registry_deps::Vector{<:AbstractString}=[],
                            subdir::AbstractString="",
                            push::Bool=false,
                            gitconfig::Dict=Dict(),)
        new(package_repo, pkg, tree_sha, registry, registry_fork,
            registry_deps, subdir, push, gitconfig,)
    end
end

register(regp::RegisterParams) = register(regp.package_repo, regp.pkg, regp.tree_sha;
                                          registry=regp.registry, registry_fork=regp.registry_fork,
                                          registry_deps=regp.registry_deps,
                                          subdir=regp.subdir, push=regp.push, gitconfig=regp.gitconfig,)

"""
    find_registered_version(pkg, registry_path)

If the package and version specified by `pkg` exists in the registry
at `registry_path`, return its tree hash. Otherwise return the empty
string.
"""
function find_registered_version(pkg::Pkg.Types.Project,
                                 registry_path::AbstractString)
    registry_file = joinpath(registry_path, "Registry.toml")
    registry_data = parse_registry(registry_file)
    # Cannot use find_package_in_registry since it may add paths in
    # the registry.
    if !haskey(registry_data.packages, string(pkg.uuid))
        return ""
    end
    package_data = registry_data.packages[string(pkg.uuid)]
    package_path = joinpath(registry_path, package_data["path"])
    _, versions_data = get_versions_file(package_path)
    if !haskey(versions_data, string(pkg.version))
        return ""
    end
    return versions_data[string(pkg.version)]["git-tree-sha1"]
end
