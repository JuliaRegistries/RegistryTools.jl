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
    registration_branch(pkg::RegistryTools.Project; url::AbstractString) -> String

Generate the name for the registry branch used to register the package version.
"""
function registration_branch(pkg::Project; url::AbstractString)
    url_hash = bytes2hex(SHA.sha256(url))
    url_hash_trunc = url_hash[1:10]
    return "registrator-$(lowercase(pkg.name))-$(string(pkg.uuid)[1:8])-v$(pkg.version)-$(url_hash_trunc)"
end

# Returns true if the two urls are the same. When the two urls are different
# returns true if the only difference between the two urls is a .git at the end
# . Returns false otherwise
function same_apart_from_dotgit(urla, urlb)
    if urla == urlb
        return true
    end

    if length(urla) > length(urlb)
        return urla[end-3:end] == ".git" && urla[1:end-4] == urlb
    else
        return urlb[end-3:end] == ".git" && urlb[1:end-4] == urla
    end
end
