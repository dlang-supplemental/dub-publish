module dub_publish.registry;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, mkdirRecurse;
import std.net.curl : CurlException, HTTP;
import std.path : dirName;
import std.string : toLower, strip;
import std.uri : encodeComponent;

import dub_publish.config : PublishConfig;

/// Result of a registry HTTP interaction.
struct RegistryResult
{
	int status;
	string body_;
	string finalUrl;
	bool ok() const @safe pure nothrow { return status >= 200 && status < 400; }
}

final class DubRegistryClient
{
	private PublishConfig cfg;

	this(PublishConfig cfg)
	{
		this.cfg = cfg;
		auto jarDir = dirName(cfg.cookieJar);
		if (jarDir.length && !exists(jarDir))
			mkdirRecurse(jarDir);
	}

	/// Log in and store the session in the cookie jar.
	void login()
	{
		enforce(cfg.user.length, "Registry username required (--user or DUB_REGISTRY_USER)");
		enforce(cfg.password.length, "Registry password required (--password or DUB_REGISTRY_PASSWORD)");

		auto form = "name=" ~ encodeComponent(cfg.user)
			~ "&password=" ~ encodeComponent(cfg.password);

		auto res = request(HTTP.Method.post, cfg.registryUrl ~ "/login", form,
			"application/x-www-form-urlencoded");

		// Success redirects to home; failure re-renders login with an error.
		auto lower = res.body_.toLower;
		enforce(!lower.canFind("invalid user name or password")
			&& !lower.canFind("invalid username or password")
			&& !(res.status == 200 && lower.canFind("please enter your user name and password")),
			"Login failed — check username/password (account must be activated)");
	}

	/// Register a repository URL. Set ignoreFork to skip the fork warning page.
	RegistryResult registerPackage(string repoUrl, bool ignoreFork = false)
	{
		enforce(repoUrl.length, "Repository URL is required");
		auto form = "url=" ~ encodeComponent(repoUrl);
		if (ignoreFork)
			form ~= "&ignore_fork=true";

		auto res = request(HTTP.Method.post, cfg.registryUrl ~ "/register_package", form,
			"application/x-www-form-urlencoded");

		auto lower = res.body_.toLower;
		if (lower.canFind("warn_fork") || lower.canFind("this repository is a fork")
			|| lower.canFind("is a fork"))
		{
			throw new Exception(
				"Repository looks like a fork. Re-run with --ignore-fork if that is intentional.");
		}
		if (lower.canFind("redalert") || (res.status == 200 && lower.canFind("add new package")
			&& lower.canFind("error")))
		{
			throw new Exception("Registration failed:\n" ~ extractAlert(res.body_));
		}
		if (res.status == 401 || res.status == 403
			|| (res.status == 200 && lower.canFind("please enter your user name and password")))
		{
			throw new Exception("Not authenticated — login first");
		}
		return res;
	}

	/// Trigger a package metadata refresh (authenticated owner action).
	RegistryResult triggerUpdate(string packageName)
	{
		enforce(packageName.length, "Package name required");
		return request(HTTP.Method.post,
			cfg.registryUrl ~ "/my_packages/" ~ encodeComponent(packageName) ~ "/update",
			null, null);
	}

	/// Trigger update via package webhook secret (no login).
	RegistryResult triggerUpdateWithSecret(string packageName, string secret)
	{
		enforce(packageName.length, "Package name required");
		enforce(secret.length, "Package secret required");
		auto url = cfg.registryUrl ~ "/api/packages/" ~ encodeComponent(packageName)
			~ "/update?secret=" ~ encodeComponent(secret);
		return request(HTTP.Method.post, url, null, null);
	}

	/// Look up whether a package exists.
	bool packageExists(string packageName)
	{
		auto res = request(HTTP.Method.get,
			cfg.registryUrl ~ "/api/packages/" ~ encodeComponent(packageName) ~ "/latest",
			null, null);
		if (res.status == 404)
			return false;
		if (!res.ok)
			throw new Exception("Status check failed HTTP " ~ res.status.to!string ~ ": " ~ res.body_);
		return res.body_.strip.length > 0;
	}

	/// Fetch latest version string, or null if missing.
	string latestVersion(string packageName)
	{
		auto res = request(HTTP.Method.get,
			cfg.registryUrl ~ "/api/packages/" ~ encodeComponent(packageName) ~ "/latest",
			null, null);
		if (res.status == 404)
			return null;
		enforce(res.ok, "Lookup failed HTTP " ~ res.status.to!string);
		return unwrapJsonString(res.body_.strip);
	}

private:
	RegistryResult request(HTTP.Method method, string url, string body_, string contentType)
	{
		auto http = HTTP();
		http.url = url;
		http.method = method;
		http.setCookieJar(cfg.cookieJar);
		http.maxRedirects = 10;
		http.addRequestHeader("User-Agent", "dub-publish/0.1 (+https://github.com/dlang-supplemental/dub-publish)");
		http.addRequestHeader("Accept", "text/html,application/json,*/*");

		if (body_ !is null)
		{
			if (contentType.length)
				http.setPostData(body_, contentType);
			else
				http.postData = body_;
		}

		auto buf = appender!string();
		http.onReceive = (ubyte[] data) {
			buf.put(cast(char[]) data);
			return data.length;
		};

		int status = 0;
		http.onReceiveStatusLine = (HTTP.StatusLine line) {
			status = cast(int) line.code;
		};

		try
			http.perform();
		catch (CurlException e)
			throw new Exception("HTTP request failed: " ~ e.msg);

		RegistryResult res;
		res.status = status;
		res.body_ = buf.data;
		res.finalUrl = url;
		return res;
	}
}

private string unwrapJsonString(string s)
{
	if (s.length >= 2 && s[0] == '"' && s[$ - 1] == '"')
		return s[1 .. $ - 1];
	return s;
}

private string extractAlert(string html)
{
	import std.regex : ctRegex, matchFirst;
	static re = ctRegex!(`<p[^>]*class="[^"]*redAlert[^"]*"[^>]*>([\s\S]*?)</p>`, "i");
	auto m = matchFirst(html, re);
	if (!m)
		return html.length > 500 ? html[0 .. 500] ~ "…" : html;
	import std.regex : replaceAll, regex;
	auto text = m[1].replaceAll(regex(`<[^>]+>`), " ").strip;
	return text.length ? text : m[1].strip;
}
