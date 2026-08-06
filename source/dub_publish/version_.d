module dub_publish.version_;

/// SemVer from VERSION at repo root (stringImportPaths).
enum string dubPublishVersion = {
	import std.string : strip;
	return import("VERSION").strip;
}();
