# Parses `container inspect` JSON (stdin) into `type|source|destination|rw`
# lines; see dx_runtime_apple_container_mounts in dx-runtime-apple.sh.
# POSIX awk only (macOS BSD awk, mawk and gawk).
function emit(   t, s) {
    t = (typ == "virtiofs") ? "bind" : (typ == "" ? "unknown" : typ)
    s = (typ == "volume" && vname != "") ? vname : src
    print t "|" s "|" dest "|" (ro ? "ro" : "rw")
}
function readstring(   out, c) {
    out = ""
    i++
    while (i <= n && (c = substr(buf, i, 1)) != "\"") {
        if (c == "\\") {
            i++
            c = substr(buf, i, 1)
            if (c != "/" && c != "\\" && c != "\"") out = out "\\"
        }
        out = out c
        i++
    }
    return out
}
function iskey(   j, c) {
    for (j = i + 1; j <= n; j++) {
        c = substr(buf, j, 1)
        if (c != " " && c != "\t" && c != "\r" && c != "\n") return c == ":"
    }
    return 0
}
{ buf = buf $0 "\n" }
END {
    n = length(buf); d = 0; md = -1
    for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        if (c == "\"") {
            s = readstring()
            if (iskey()) {
                key[d] = s
                if (inm && d == md + 2 && key[md + 1] == "type" && typ == "") typ = s
                if (inm && d == md + 3 && key[md + 1] == "type" && key[md + 2] == "volume" && s == "name") wantname = 1
            } else if (inm) {
                if (d == md + 1 && key[d] == "destination") dest = s
                else if (d == md + 1 && key[d] == "source") src = s
                else if (d == md + 2 && key[md + 1] == "options" && s == "ro") ro = 1
                else if (wantname && d == md + 3) vname = s
                wantname = 0
            }
        } else if (c == "{" || c == "[") {
            if (c == "[" && md < 0 && key[d] == "mounts") md = d + 1
            else if (c == "{" && d == md) { inm = 1; dest = ""; src = ""; typ = ""; vname = ""; ro = 0; wantname = 0 }
            d++
            key[d] = ""
        } else if (c == "}" || c == "]") {
            d--
            if (c == "}" && inm && d == md) { emit(); inm = 0 }
            else if (c == "]" && d == md - 1 && md >= 0) exit
        }
    }
}
