module dub_publish.registry;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, read;
import std.net.curl : CurlException, HTTP;
import std.path : baseName, dirName;
import std.string : representation, toLower, strip;
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

/// Webhook endpoint URLs (always built clean — avoids dub-registry #614 malformation).
struct WebhookUrls
{
	string generic;
	string github;
	string gitlab;
	string secret;
}

WebhookUrls buildWebhookUrls(string registryUrl, string packageName, string secret)
{
	normalizeRegistryUrl(registryUrl);
	auto base = registryUrl ~ "/api/packages/" ~ encodeComponent(packageName);
	WebhookUrls u;
	u.secret = secret;
	u.generic = base ~ "/update";
	u.github = base ~ "/update/github?secret=" ~ encodeComponent(secret);
	u.gitlab = base ~ "/update/gitlab";
	return u;
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

		auto lower = res.body_.toLower;
		enforce(!lower.canFind("invalid user name or password")
			&& !lower.canFind("invalid username or password")
			&& !(res.status == 200 && lower.canFind("please enter your user name and password")),
			"Login failed — check username/password (account must be activated)");
	}

	/// Register a repository URL. Throws AlreadyRegisteredException when already present.
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
			&& (lower.canFind("error") || lower.canFind("failed"))))
		{
			auto alert = extractAlert(res.body_);
			if (isAlreadyRegisteredMessage(alert))
				throw new AlreadyRegisteredException(alert);
			throw new Exception("Registration failed:\n" ~ alert);
		}
		// Successful registration usually redirects away from the add form.
		if (res.status == 200 && lower.canFind("add new package")
			&& lower.canFind("register package"))
		{
			throw new Exception(
				"Registration did not complete (still on add-package form). "
				~ "Check credentials and repository URL.\n" ~ extractAlert(res.body_));
		}
		enforceAuth(res, lower);
		return res;
	}

	RegistryResult triggerUpdate(string packageName)
	{
		enforce(packageName.length, "Package name required");
		return request(HTTP.Method.post,
			pkgPath(packageName) ~ "/update", null, null);
	}

	RegistryResult triggerUpdateWithSecret(string packageName, string secret)
	{
		enforce(packageName.length, "Package name required");
		enforce(secret.length, "Package secret required");
		auto url = cfg.registryUrl ~ "/api/packages/" ~ encodeComponent(packageName)
			~ "/update?secret=" ~ encodeComponent(secret);
		return request(HTTP.Method.post, url, null, null);
	}

	/// Enable or regenerate webhook secret. Returns plaintext secret (Accept: text/plain).
	string regenSecret(string packageName)
	{
		enforce(packageName.length, "Package name required");
		auto res = request(HTTP.Method.post, pkgPath(packageName) ~ "/regen_secret",
			null, null, "text/plain");
		enforce(res.ok, "regen_secret failed HTTP " ~ res.status.to!string ~ ": " ~ res.body_);
		auto secret = res.body_.strip;
		enforce(secret.length > 0, "Registry returned an empty webhook secret");
		return secret;
	}

	RegistryResult unsetSecret(string packageName)
	{
		enforce(packageName.length, "Package name required");
		return request(HTTP.Method.post, pkgPath(packageName) ~ "/unset_secret", null, null);
	}

	RegistryResult setDocumentationUrl(string packageName, string documentationUrl)
	{
		enforce(packageName.length, "Package name required");
		auto form = "documentation_url=" ~ encodeComponent(documentationUrl);
		return request(HTTP.Method.post, pkgPath(packageName) ~ "/set_documentation_url",
			form, "application/x-www-form-urlencoded");
	}

	RegistryResult setCategories(string packageName, string[] categories)
	{
		enforce(packageName.length, "Package name required");
		enforce(categories.length <= 4, "At most 4 categories allowed");
		string form;
		foreach (i, cat; categories)
		{
			if (form.length)
				form ~= "&";
			form ~= "categories_" ~ i.to!string ~ "=" ~ encodeComponent(cat);
		}
		// Pad to 4 slots like the web UI (empty clears unused).
		foreach (i; categories.length .. 4)
		{
			if (form.length)
				form ~= "&";
			form ~= "categories_" ~ i.to!string ~ "=";
		}
		return request(HTTP.Method.post, pkgPath(packageName) ~ "/set_categories",
			form, "application/x-www-form-urlencoded");
	}

	RegistryResult setLogo(string packageName, string logoPath)
	{
		enforce(packageName.length, "Package name required");
		enforce(exists(logoPath), "Logo file not found: " ~ logoPath);
		auto bytes = cast(const(ubyte)[]) read(logoPath);
		enforce(bytes.length < 1024 * 1024, "Logo too big (max 1 MiB)");
		enforce(bytes.length > 0, "Logo file is empty");

		auto boundary = "----dubpublishBoundary7d4a6e";
		auto filename = baseName(logoPath);
		auto preamble = "--" ~ boundary ~ "\r\n"
			~ "Content-Disposition: form-data; name=\"logo\"; filename=\"" ~ filename ~ "\"\r\n"
			~ "Content-Type: application/octet-stream\r\n\r\n";
		auto epilogue = "\r\n--" ~ boundary ~ "--\r\n";
		auto bodyBytes = cast(ubyte[])(preamble.representation.dup)
			~ bytes
			~ cast(ubyte[])(epilogue.representation);

		return requestRaw(HTTP.Method.post, pkgPath(packageName) ~ "/set_logo",
			bodyBytes, "multipart/form-data; boundary=" ~ boundary);
	}

	RegistryResult deleteLogo(string packageName)
	{
		enforce(packageName.length, "Package name required");
		return request(HTTP.Method.post, pkgPath(packageName) ~ "/delete_logo", null, null);
	}

	RegistryResult setRepository(string packageName, string kind, string owner, string project)
	{
		enforce(packageName.length, "Package name required");
		auto form = "kind=" ~ encodeComponent(kind)
			~ "&owner=" ~ encodeComponent(owner)
			~ "&project=" ~ encodeComponent(project);
		return request(HTTP.Method.post, pkgPath(packageName) ~ "/set_repository",
			form, "application/x-www-form-urlencoded");
	}

	RegistryResult addSharedUser(string packageName, string username, uint permissions)
	{
		enforce(packageName.length, "Package name required");
		enforce(username.length, "Username required");
		// Multiple permissions fields with same name; encode as repeated keys.
		string form = "username=" ~ encodeComponent(username);
		foreach (bit; [1u, 2u, 4u, 15u])
		{
			if (permissions & bit)
				form ~= "&permissions=" ~ bit.to!string;
		}
		return request(HTTP.Method.post, pkgPath(packageName) ~ "/add_shared_user",
			form, "application/x-www-form-urlencoded");
	}

	/// Step 1 of owner delete — shows confirm page; we immediately follow with remove_confirm.
	RegistryResult removePackage(string packageName)
	{
		enforce(packageName.length, "Package name required");
		auto step1 = request(HTTP.Method.post, pkgPath(packageName) ~ "/remove", null, null);
		enforce(step1.ok || step1.status == 200,
			"remove failed HTTP " ~ step1.status.to!string ~ ": " ~ extractAlert(step1.body_));
		return request(HTTP.Method.post, pkgPath(packageName) ~ "/remove_confirm", null, null);
	}

	RegistryResult leavePackage(string packageName)
	{
		enforce(packageName.length, "Package name required");
		return request(HTTP.Method.post, pkgPath(packageName) ~ "/leave", null, null);
	}

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
	string pkgPath(string packageName)
	{
		return cfg.registryUrl ~ "/my_packages/" ~ encodeComponent(packageName);
	}

	void enforceAuth(RegistryResult res, string lower)
	{
		if (res.status == 401 || res.status == 403
			|| (res.status == 200 && lower.canFind("please enter your user name and password")))
		{
			throw new Exception("Not authenticated — login first");
		}
	}

	RegistryResult request(HTTP.Method method, string url, string body_, string contentType,
		string accept = "text/html,application/json,*/*")
	{
		const(ubyte)[] raw;
		if (body_ !is null)
			raw = cast(const(ubyte)[]) body_.representation;
		return requestRaw(method, url, raw, contentType, accept);
	}

	RegistryResult requestRaw(HTTP.Method method, string url, const(ubyte)[] bodyBytes,
		string contentType, string accept = "text/html,application/json,*/*")
	{
		auto http = HTTP();
		http.url = url;
		http.method = method;
		http.setCookieJar(cfg.cookieJar);
		http.maxRedirects = 10;
		http.addRequestHeader("User-Agent",
			"dub-publish/0.2 (+https://github.com/dlang-supplemental/dub-publish)");
		http.addRequestHeader("Accept", accept);

		if (bodyBytes !is null)
		{
			if (contentType.length)
				http.setPostData(cast(void[]) bodyBytes.dup, contentType);
			else
				http.postData = cast(void[]) bodyBytes.dup;
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

class AlreadyRegisteredException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

bool isAlreadyRegisteredMessage(string alert)
{
	auto lower = alert.toLower;
	return lower.canFind("already registered")
		|| lower.canFind("already exists")
		|| lower.canFind("is already registered");
}

private void normalizeRegistryUrl(ref string url)
{
	import dub_publish.config : normalizeRegistryUrl;
	normalizeRegistryUrl(url);
}

private string unwrapJsonString(string s)
{
	if (s.length >= 2 && s[0] == '"' && s[$ - 1] == '"')
		return s[1 .. $ - 1];
	return s;
}

private string extractAlert(string html)
{
	import std.regex : ctRegex, matchFirst, replaceAll, regex;
	static re = ctRegex!(`<p[^>]*class="[^"]*redAlert[^"]*"[^>]*>([\s\S]*?)</p>`, "i");
	auto m = matchFirst(html, re);
	if (!m)
		return html.length > 500 ? html[0 .. 500] ~ "…" : html;
	auto text = m[1].replaceAll(regex(`<[^>]+>`), " ").strip;
	return text.length ? text : m[1].strip;
}
