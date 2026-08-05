import Foundation

setvbuf(stdout, nil, _IOLBF, 0)   // launchd redirects to a file, where block buffering hides lines until a crash

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("aerialite: \(message)\n".utf8))
    exit(1)
}

let argv = Array(CommandLine.arguments.dropFirst())
switch argv.first {
case "prep": Prep.main(Array(argv.dropFirst()))
case "catalog": CatalogImport.main()
case "play", nil: MainActor.assumeIsolated { App.run() }   // top-level code already runs on main
case let other: fail("unknown command \(other!)\nusage: aerialite [play] | aerialite prep <input> [flags] | aerialite catalog")
}
