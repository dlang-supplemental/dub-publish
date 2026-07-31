module dub_publish.config;

import std.file : exists, mkdirRecurse, remove, write, readText;
import std.path : buildPath, expandTilde;
import std.string : strip, startsWith;

import dub_publish.secrets;

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
		string loadedUser;
		string loadedPassword;
		bool fromLegacy;
		if (loadStoredCredentials(loadedUser, loadedPassword, fromLegacy))
		{
			if (!cfg.user.length)
				cfg.user = loadedUser;
			if (!cfg.password.length)
				cfg.password = loadedPassword;
			// Upgrade pre-0.3.0 plaintext files on first successful read.
			if (fromLegacy && cfg.user.length && cfg.password.length
				&& cfg.user == loadedUser && cfg.password == loadedPassword)
			{
				try
					saveCredentials(cfg.user, cfg.password);
				catch (Exception)
				{
					// Keep using the in-memory password; leave legacy file alone.
				}
			}
		}
	}

	normalizeRegistryUrl(cfg.registryUrl);
	return cfg;
}

/**
 * Persist username/password for later runs.
 *
 * The password is not hashed: a hash cannot be sent to the registry on later
 * logins. On Windows the secret is protected with DPAPI (bound to the current
 * user). Elsewhere it is stored Base64-encoded under mode 0600 (OS file ACLs).
 */
void saveCredentials(string user, string password)
{
	auto home = configDir();
	mkdirRecurse(home);
	auto path = credentialsPath();
	auto body = "version=1\n"
		~ "user=" ~ user ~ "\n"
		~ "password=" ~ protectSecret(password) ~ "\n";
	write(path, body);
	version (Posix)
	{
		import core.sys.posix.sys.stat : chmod;
		import std.conv : octal;
		import std.string : toStringz;
		chmod(path.toStringz, octal!600);
	}
	// Remove legacy plaintext file if present alongside the new format.
	auto legacy = buildPath(home, "credentials");
	if (legacy != path && exists(legacy))
	{
		try
			remove(legacy);
		catch (Exception)
		{
		}
	}
}

/// Delete stored credentials (new + legacy filenames).
bool clearCredentials()
{
	bool removed;
	foreach (name; ["credentials.v1", "credentials"])
	{
		auto path = buildPath(configDir(), name);
		if (exists(path))
		{
			remove(path);
			removed = true;
		}
	}
	return removed;
}

string credentialsPath()
{
	return buildPath(configDir(), "credentials.v1");
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

/// Load from credentials.v1 or legacy plaintext `credentials`.
private bool loadStoredCredentials(out string user, out string password, out bool fromLegacy)
{
	auto v1 = credentialsPath();
	if (exists(v1))
	{
		parseCredentialFile(readText(v1), user, password);
		fromLegacy = false;
		return user.length > 0 || password.length > 0;
	}

	auto legacy = buildPath(configDir(), "credentials");
	if (exists(legacy))
	{
		auto lines = splitLinesSafe(readText(legacy));
		if (lines.length >= 1)
			user = lines[0].strip;
		if (lines.length >= 2)
			password = lines[1].strip;
		fromLegacy = true;
		return user.length > 0 || password.length > 0;
	}
	return false;
}

private void parseCredentialFile(string text, out string user, out string password)
{
	foreach (line; splitLinesSafe(text))
	{
		auto s = line.strip;
		if (!s.length || s.startsWith("#"))
			continue;
		if (s.startsWith("user="))
			user = s["user=".length .. $];
		else if (s.startsWith("password="))
			password = unprotectSecret(s["password=".length .. $]);
	}
}

private string[] splitLinesSafe(string text)
{
	import std.array : array;
	import std.string : lineSplitter;
	return text.lineSplitter.array;
}
