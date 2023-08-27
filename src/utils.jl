import SHA

showsafe(x) = (x === nothing) ? "nothing" : x

function gitcmd(path::AbstractString, gitconfig::Dict)
    cmd = ["git", "-C", path]
    for (n,v) in gitconfig
        push!(cmd, "-c")
        push!(cmd, "$n=$v")
    end
    Cmd(cmd)
end

"""
    registration_branch(pkg::AbstractString; url::AbstractString) -> String
    registration_branch(pkg::RegistryTools.Project; url::AbstractString) -> String

Generate the name for the registry branch used to register the package version.
"""
function registration_branch(pkg::Project; url::AbstractString)
    url_hash = bytes2hex(SHA.sha256(url))
    url_hash_trunc = url_hash[1:10]
    # NOTE: If this format is changed TagBot must be updated
    # https://github.com/JuliaRegistries/TagBot/blob/4e2dfa4ac8ad1e1a0af1e03f8411855200fac8ce/tagbot/action/repo.py#L219
    return "registrator-$(lowercase(pkg.name))-$(string(pkg.uuid)[1:8])-v$(pkg.version)-$(url_hash_trunc)"
end
function registration_branch(project_file::AbstractString; url::AbstractString)
    proj = Project(project_file)
    return registration_branch(proj; url = url)
end
