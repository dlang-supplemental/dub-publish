module dub_publish.recipe;

import std.file : exists, readText;
import std.path : buildPath;
import std.regex : ctRegex, matchFirst;
import std.string : strip;

/// Read the package `name` from dub.json or dub.sdl in `dir`.
string readPackageName(string dir = ".")
{
	auto jsonPath = buildPath(dir, "dub.json");
	if (exists(jsonPath))
		return parseJsonName(readText(jsonPath));

	auto sdlPath = buildPath(dir, "dub.sdl");
	if (exists(sdlPath))
		return parseSdlName(readText(sdlPath));

	return null;
}

private string parseJsonName(string text)
{
	// Minimal extract — avoids a JSON dependency for one field.
	static nameRe = ctRegex!(`"name"\s*:\s*"([^"]+)"`);
	auto m = matchFirst(text, nameRe);
	return m ? m[1] : null;
}

private string parseSdlName(string text)
{
	static nameRe = ctRegex!(`(?m)^\s*name\s+"([^"]+)"`);
	auto m = matchFirst(text, nameRe);
	if (m)
		return m[1];
	static nameRe2 = ctRegex!(`(?m)^\s*name\s+([^\s#]+)`);
	auto m2 = matchFirst(text, nameRe2);
	return m2 ? m2[1].strip : null;
}
