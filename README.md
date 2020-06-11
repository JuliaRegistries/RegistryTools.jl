# RegistryTools

[![Project Status: Active - The project has reached a stable, usable state and is being actively developed.](http://www.repostatus.org/badges/latest/active.svg)](http://www.repostatus.org/#active)
[![Build Status](https://travis-ci.com/JuliaRegistries/RegistryTools.jl.svg?branch=master)](https://travis-ci.com/JuliaRegistries/RegistryTools.jl)
[![codecov](https://codecov.io/gh/JuliaRegistries/RegistryTools.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaRegistries/RegistryTools.jl)

Functionality for modifying Julia registry files. 

## Setting up and using an additional registry

You can use these tools to setup and maintain your own (private) registry of julia packages. 
This way register/tag packages you do not want to register in the "General" registry and let the
package manager figure out about versions, dependencies etc... 

### Create a registry

First create an empty repo at [github.com](https://github.com) (or an on prem alternative), e.g.`username/MyRegistry.git`. In the following `"git@github.com:username/MyRegistry.git"` has to be adjusted appropriately.   Then start `julia`:

```julia
using RegistryTools, Pkg, UUIDs

registry_name = "MyRegistry"
registry_repo = "git@github.com:username/MyRegistry.git"

path = "."
uuid = string(UUIDs.uuid4())


rd = RegistryTools.RegistryData(registry_name, uuid, repo = registry_repo)
RegistryTools.write_registry(joinpath(path, "Registry.toml"), rd)
```

Now git init, add, commit and push the `Registry.toml` to the repo from your shell (adjusting the remote):

```bash
git init
git add Registry.toml
git commit -m "first commit"
git remote add origin git@github.com:username/MyRegistry.git
git push -u origin master
```

The local git repo and `Registry.toml` can be trashed. The registry is still empty - to be useful follow along.


### Add a registry to the package manager

To make the package manager aware of your new registry add it like this:

```
pkg> registry add git@github.com:username/MyRegistry.git
```
The package manager will now pull updates as it is done for the "General" registry

### Register a new package or tag a release 

To use the julia package manager to take care about versions and dependencies of your (private) packages you can now 
register and tag them like this:

* if tagging a new version of an already (in your registry) registered package bump the version number in its `Project.toml`
* git commit and push the package
* startup julia, adjust the function arguments in the last line appropriately and run the following code. Double check whether the `tree_hash` points to the right commit you want to register.

```julia
using RegistryTools, Pkg

function myregister(registry_repo, package_path, tree_hash = nothing)

	package_repo = chomp(read(Cmd(`git remote get-url --all origin`, dir = package_path), String))
	pkg = Pkg.Types.read_project(joinpath(package_path, "Project.toml"))
	if tree_hash == nothing
		possible_hashes = readlines(Cmd(`git log --pretty=format:'%T %s'`, dir = package_path))

		println(join(possible_hashes, "\n"))
		
		tree_hash = possible_hashes[1] |> split |> first
		@show tree_hash
	end

	r = RegistryTools.register(
		package_repo, pkg, tree_hash,
		registry = registry_repo,
		registry_deps = [RegistryTools.DEFAULT_REGISTRY_URL],
		push = true
	)
end


registry_repo = "git@github.com:username/MyRegistry.git"
package_path  = joinpath(DEPOT_PATH, "dev/MyPackage")

myregister(registry_repo, package_path)
```

* Now visit the website of the repo of your registry to create and merge a PR.

