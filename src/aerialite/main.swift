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
case "activate-native":
    do {
        try NativeActivation.activate()
        print("native wallpaper extension registered and active")
    } catch {
        fail("native activation failed: \(error.localizedDescription)")
    }
case "play", nil:
    guard SingleInstance.acquire() else {
        fail("another aerialite agent is already running and owns the wallpaper")
    }
    MainActor.assumeIsolated { App.run() }   // top-level code already runs on main
case let other: fail("unknown command \(other!)\nusage: aerialite [play] | aerialite prep <input> [flags] | aerialite catalog")
}
