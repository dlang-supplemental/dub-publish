module app;

import std.algorithm : among, canFind, startsWith;
import std.getopt;
import std.stdio;
import std.string : strip;

import dub_publish;

int main(string[] args)
{
	string registry;
	string user;
	string password;
	string url;
	string secret;
	string packageName;
	string root = ".";
	bool ignoreFork;
	bool dryRun;
	bool saveCreds;
	bool help;

	string command = "register";
	string[] rest;
	if (args.length >= 2 && !args[1].startsWith("-"))
	{
		auto c = args[1];
		if (c.among!("register", "publish", "update", "status", "login", "help"))
		{
			command = c == "publish" ? "register" : c;
			rest = args[0] ~ args[2 .. $];
		}
		else
			rest = args;
	}
	else
		rest = args;

	if (command == "help")
	{
		printHelp();
		return 0;
	}

	try
	{
		auto opts = getopt(rest,
			"registry", "Registry base URL (default https://code.dlang.org)", &registry,
			"user|u", "Registry username or email (or DUB_REGISTRY_USER)", &user,
			"password|p", "Registry password (or DUB_REGISTRY_PASSWORD)", &password,
			"url", "Repository URL (default: git remote origin)", &url,
			"package|n", "Package name (default: from dub.json / dub.sdl)", &packageName,
			"secret", "Package update webhook secret", &secret,
			"root", "Package directory for recipe/git detection", &root,
			"ignore-fork", "Register even if the repository is a fork", &ignoreFork,
			"dry-run", "Print actions without contacting the registry", &dryRun,
			"save-credentials", "Save username/password under the local config dir", &saveCreds,
			"h|help", "Show help", &help,
		);
		if (help || opts.helpWanted)
		{
			printHelp();
			return 0;
		}
	}
	catch (Exception e)
	{
		stderr.writeln("error: ", e.msg);
		printHelp();
		return 2;
	}

	auto cfg = loadConfig(registry, user, password);
	if (saveCreds)
	{
		if (!cfg.user.length || !cfg.password.length)
		{
			stderr.writeln("error: --save-credentials needs --user and --password (or env vars)");
			return 2;
		}
		saveCredentials(cfg.user, cfg.password);
		writeln("Saved credentials to ", configDir());
		if (command == "login")
			return 0;
	}

	try
	{
		switch (command)
		{
		case "login":
			return cmdLogin(cfg, dryRun);
		case "register":
			return cmdRegister(cfg, root, url, ignoreFork, dryRun);
		case "update":
			return cmdUpdate(cfg, root, packageName, secret, dryRun);
		case "status":
			return cmdStatus(cfg, root, packageName, dryRun);
		default:
			printHelp();
			return 2;
		}
	}
	catch (Exception e)
	{
		stderr.writeln("error: ", e.msg);
		return 1;
	}
}

int cmdLogin(PublishConfig cfg, bool dryRun)
{
	if (dryRun)
	{
		writeln("Would log in to ", cfg.registryUrl, " as ", cfg.user);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	writeln("Logged in to ", cfg.registryUrl, " as ", cfg.user);
	return 0;
}

int cmdRegister(PublishConfig cfg, string root, string url, bool ignoreFork, bool dryRun)
{
	if (!url.length)
		url = detectGitRemoteUrl("origin", root);
	enforceMsg(url.length > 0,
		"No repository URL — pass --url or run inside a git repo with an origin remote");

	auto name = readPackageName(root);
	writeln("Registry:   ", cfg.registryUrl);
	writeln("Repository: ", url);
	if (name.length)
		writeln("Package:    ", name);

	if (dryRun)
	{
		writeln("Dry run — not submitting.");
		return 0;
	}

	auto client = new DubRegistryClient(cfg);
	client.login();
	client.registerPackage(url, ignoreFork);

	if (name.length)
	{
		import core.thread : Thread;
		import core.time : seconds;
		// Registry queues ingestion; brief wait then report status.
		Thread.sleep(2.seconds);
		if (client.packageExists(name))
		{
			auto ver = client.latestVersion(name);
			writeln("Registered. Latest: ", ver.length ? ver : "(pending)");
			writeln(cfg.registryUrl, "/packages/", name);
			return 0;
		}
		writeln("Submitted. Package may take a minute to appear at ");
		writeln(cfg.registryUrl, "/packages/", name);
	}
	else
		writeln("Submitted. Check ", cfg.registryUrl, "/my_packages");
	return 0;
}

int cmdUpdate(PublishConfig cfg, string root, string packageName, string secret, bool dryRun)
{
	if (!packageName.length)
		packageName = readPackageName(root);
	enforceMsg(packageName.length > 0, "Package name required (--package or dub recipe in --root)");

	if (dryRun)
	{
		writeln("Would trigger update for ", packageName, " on ", cfg.registryUrl);
		return 0;
	}

	auto client = new DubRegistryClient(cfg);
	RegistryResult res;
	if (secret.length)
		res = client.triggerUpdateWithSecret(packageName, secret);
	else
	{
		client.login();
		res = client.triggerUpdate(packageName);
	}
	writeln("Update queued for ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

int cmdStatus(PublishConfig cfg, string root, string packageName, bool dryRun)
{
	if (!packageName.length)
		packageName = readPackageName(root);
	enforceMsg(packageName.length > 0, "Package name required (--package or dub recipe in --root)");

	if (dryRun)
	{
		writeln("Would check status of ", packageName, " on ", cfg.registryUrl);
		return 0;
	}

	auto client = new DubRegistryClient(cfg);
	auto ver = client.latestVersion(packageName);
	if (ver is null)
	{
		writeln(packageName, ": not found on ", cfg.registryUrl);
		return 1;
	}
	writeln(packageName, ": ", ver);
	writeln(cfg.registryUrl, "/packages/", packageName);
	return 0;
}

void enforceMsg(bool cond, string msg)
{
	import std.exception : enforce;
	enforce(cond, msg);
}

void printHelp()
{
	writeln(`dub-publish — register a Git repository with the DUB registry

Official dub has no publish command; registration is normally done in the
browser at code.dlang.org. This tool automates that flow.

Usage:
  dub-publish [register|publish] [options]
  dub-publish update  [options]
  dub-publish status  [options]
  dub-publish login   [options]

Options:
  --registry URL       Registry base URL (default https://code.dlang.org)
  --user, -u NAME      Username or email (env: DUB_REGISTRY_USER)
  --password, -p PASS  Password (env: DUB_REGISTRY_PASSWORD)
  --url URL            Repository URL (default: git remote origin)
  --package, -n NAME   Package name (default: from dub.json / dub.sdl)
  --secret SECRET      Webhook secret for unauthenticated update
  --root DIR           Package directory (default: .)
  --ignore-fork        Allow registering a forked repository
  --dry-run            Print actions only
  --save-credentials   Store user/password in the local config dir
  -h, --help           Show this help

Examples:
  set DUB_REGISTRY_USER=me
  set DUB_REGISTRY_PASSWORD=secret
  dub-publish --root ../vello-d

  dub-publish status -n vello-d
  dub-publish update -n vello-d --secret YOUR_PACKAGE_SECRET
`);
}
