local path = {}

function path.dirname(file)
    return (file:match("^(.*)/[^/]+$")) or "."
end

return path
