module dub_publish.config;

import std.file : exists, mkdirRecurse, readText, write;
import std.path : buildPath, expandTilde;
import std.string : strip;

/// Credentials and defaults for talking to a DUB registry.
struct PublishConfig
{
	string registryUrl = "https://code.dlang.org";
	string user;
	string password;
	string cookieJar;
}

/// Resolve config from CLI overrides, environment, then optional config file.
PublishConfig loadConfig(string registryOverride = null, string userOverride = null,
	string passwordOverride = null)
{
	import std.process : environment;

	PublishConfig cfg;
	if (registryOverride.length)
		cfg.registryUrl = registryOverride;
	else if (auto r = environment.get("DUB_REGISTRY_URL"))
		cfg.registryUrl = r;

	if (userOverride.length)
		cfg.user = userOverride;
	else if (auto u = environment.get("DUB_REGISTRY_USER"))
		cfg.user = u;

	if (passwordOverride.length)
		cfg.password = passwordOverride;
	else if (auto p = environment.get("DUB_REGISTRY_PASSWORD"))
		cfg.password = p;

	auto home = configDir();
	cfg.cookieJar = buildPath(home, "cookies.txt");

	if (!cfg.user.length || !cfg.password.length)
	{
		auto credPath = buildPath(home, "credentials");
		if (exists(credPath))
		{
			auto lines = readText(credPath).splitLinesSafe();
			if (!cfg.user.length && lines.length >= 1)
				cfg.user = lines[0].strip;
			if (!cfg.password.length && lines.length >= 2)
				cfg.password = lines[1].strip;
		}
	}

	normalizeRegistryUrl(cfg.registryUrl);
	return cfg;
}

/// Persist username/password for later runs (plain text; mode left to OS ACLs).
void saveCredentials(string user, string password)
{
	auto home = configDir();
	mkdirRecurse(home);
	write(buildPath(home, "credentials"), user ~ "\n" ~ password ~ "\n");
}

string configDir()
{
	version (Windows)
	{
		import std.process : environment;
		auto base = environment.get("LOCALAPPDATA");
		if (!base.length)
			base = expandTilde("~");
		return buildPath(base, "dlang-supplemental", "dub-publish");
	}
	else
	{
		return expandTilde("~/.dlang-supplemental/dub-publish");
	}
}

void normalizeRegistryUrl(ref string url)
{
	import std.algorithm : endsWith;
	if (!url.length)
		url = "https://code.dlang.org";
	while (url.endsWith("/"))
		url = url[0 .. $ - 1];
}

private string[] splitLinesSafe(string text)
{
	import std.array : split;
	import std.string : lineSplitter;
	import std.array : array;
	return text.lineSplitter.array;
}
