# json2dir-julia

[json2dir](https://github.com/kitsunoff/awesome-json2dir) in Julia, using only Base (it has its own JSON parser). It reads a JSON document from stdin and creates the tree it describes in the current directory.

    julia --startup-file=no --compile=min -O0 json2dir.jl < tree.json
