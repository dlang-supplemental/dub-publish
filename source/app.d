module app;

import std.algorithm : among, startsWith;
import std.array : join;
import std.conv : to;
import std.file : mkdirRecurse, write;
import std.getopt;
import std.path : buildPath, dirName;
import std.stdio;
import std.string : strip, toLower;

import dub_publish;
import dub_publish.version_;

int main(string[] args)
{
	string registry;
	string user;
	string password;
	string passwordFile;
	string url;
	string secret;
	string packageName;
	string root = ".";
	string logoPath;
	string docsUrl;
	string hooksOut;
	string secretOut;
	string repoKind;
	string repoOwner;
	string repoProject;
	string sharedUsername;
	string[] categories;
	string[] permFlags;
	bool ignoreFork;
	bool dryRun;
	bool saveCreds;
	bool promptPw;
	bool yes;
	bool help;

	string command = "register";
	string[] rest;
	if (args.length >= 2 && !args[1].startsWith("-"))
	{
		auto c = args[1];
		if (c.among!(
				"register", "publish", "update", "status", "login", "logout", "help",
				"version", "--version",
				"remove", "logo", "logo-delete", "docs-url", "categories",
				"hooks", "hooks-disable", "repo", "perms-add", "leave"))
		{
			if (c == "version" || c == "--version")
			{
				writeln("dub-publish ", dubPublishVersion);
				return 0;
			}
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
			"password|p", "Registry password (or DUB_REGISTRY_PASSWORD); visible in shell history / process list", &password,
			"password-file", "Read password from file (first line); preferred for scripts/agents", &passwordFile,
			"prompt-password", "Interactively prompt for password (TTY, no echo)", &promptPw,
			"url", "Repository URL (default: git remote origin)", &url,
			"package|n", "Package name (default: from dub.json / dub.sdl)", &packageName,
			"secret", "Package update webhook secret", &secret,
			"root", "Package directory for recipe/git detection", &root,
			"logo-file", "Path to logo image (png/jpeg/gif/bmp, max 1 MiB)", &logoPath,
			"docs-url", "Documentation URL (http/https)", &docsUrl,
			"category", "Category id (repeatable, max 4)", &categories,
			"hooks-out", "Write webhook URLs to this file", &hooksOut,
			"secret-out", "Write webhook secret to this file (default: <configDir>/hooks/<pkg>.secret)", &secretOut,
			"kind", "Repository kind (github|gitlab|bitbucket|gitea|forgejo)", &repoKind,
			"owner", "Repository owner", &repoOwner,
			"project", "Repository project/name", &repoProject,
			"username", "code.dlang.org username for perms-add", &sharedUsername,
			"perm", "Permission flag for perms-add: update|metadata|source|admin (repeatable)", &permFlags,
			"ignore-fork", "Allow registering a forked repository", &ignoreFork,
			"dry-run", "Print actions without contacting the registry", &dryRun,
			"save-credentials", "Save username/password locally (DPAPI on Windows; mode 0600 elsewhere)", &saveCreds,
			"yes|y", "Confirm destructive actions (remove)", &yes,
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

	bool passwordFromExplicit;
	if (passwordFile.length)
	{
		if (password.length)
		{
			stderr.writeln("error: do not combine --password with --password-file");
			return 2;
		}
		try
			password = readPasswordFile(passwordFile);
		catch (Exception e)
		{
			stderr.writeln("error: ", e.msg);
			return 2;
		}
		passwordFromExplicit = true;
	}
	else if (password.length)
		passwordFromExplicit = true;

	auto cfg = loadConfig(registry, user, password);
	if (command == "logout")
	{
		if (dryRun)
		{
			writeln("Would clear stored credentials under ", configDir());
			return 0;
		}
		if (clearCredentials())
			writeln("Cleared stored credentials under ", configDir());
		else
			writeln("No stored credentials found under ", configDir());
		return 0;
	}

	// Default drop file: consumed with --save-credentials when no CLI/env password.
	// Prefer drop over an already-stored credential so agents can rotate.
	import std.file : exists;
	import std.process : environment;
	bool fromEnv = !passwordFromExplicit
		&& environment.get("DUB_REGISTRY_PASSWORD", "").length > 0;
	if (saveCreds && !passwordFromExplicit && !fromEnv && exists(passwordDropPath()))
	{
		try
			cfg.password = readPasswordFile(passwordDropPath());
		catch (Exception e)
		{
			stderr.writeln("error: ", e.msg);
			return 2;
		}
	}

	if (!cfg.password.length && promptPw)
	{
		cfg.password = promptPassword("DUB registry password: ");
		if (!cfg.password.length)
		{
			stderr.writeln("error: empty password");
			return 2;
		}
	}

	if (saveCreds || command == "login")
	{
		if (!cfg.user.length)
		{
			stderr.writeln("error: pass --user (or DUB_REGISTRY_USER)");
			return 2;
		}
		if (!cfg.password.length)
		{
			stderr.writeln("error: password required — write it to:");
			stderr.writeln("       ", passwordDropPath());
			stderr.writeln("       then re-run with --save-credentials");
			stderr.writeln("       (or use --password-file / -p / env / --prompt-password)");
			return 2;
		}
	}

	if (saveCreds)
	{
		auto saveRc = persistCredentialsVerified(cfg, dryRun);
		if (saveRc != 0)
			return saveRc;
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
			return cmdRegister(cfg, root, url, packageName, ignoreFork, dryRun);
		case "update":
			return cmdUpdate(cfg, root, packageName, secret, dryRun);
		case "status":
			return cmdStatus(cfg, root, packageName, dryRun);
		case "remove":
			return cmdRemove(cfg, root, packageName, yes, dryRun);
		case "logo":
			return cmdLogo(cfg, root, packageName, logoPath, dryRun);
		case "logo-delete":
			return cmdLogoDelete(cfg, root, packageName, dryRun);
		case "docs-url":
			return cmdDocsUrl(cfg, root, packageName, docsUrl, dryRun);
		case "categories":
			return cmdCategories(cfg, root, packageName, categories, dryRun);
		case "hooks":
			return cmdHooks(cfg, root, packageName, secretOut, hooksOut, dryRun);
		case "hooks-disable":
			return cmdHooksDisable(cfg, root, packageName, dryRun);
		case "repo":
			return cmdRepo(cfg, root, packageName, repoKind, repoOwner, repoProject, dryRun);
		case "perms-add":
			return cmdPermsAdd(cfg, root, packageName, sharedUsername, permFlags, dryRun);
		case "leave":
			return cmdLeave(cfg, root, packageName, dryRun);
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

/// Verify registry login, then write the protected store and delete password.incoming.
int persistCredentialsVerified(PublishConfig cfg, bool dryRun)
{
	import std.file : exists;

	if (dryRun)
	{
		writeln("Would verify login as ", cfg.user, " on ", cfg.registryUrl);
		writeln("Would save credentials under ", configDir());
		if (exists(passwordDropPath()))
			writeln("Would remove password drop file ", passwordDropPath());
		return 0;
	}
	try
	{
		auto client = new DubRegistryClient(cfg);
		client.login();
	}
	catch (Exception e)
	{
		stderr.writeln("error: ", e.msg);
		stderr.writeln("Not saving credentials; password drop file left in place if present.");
		return 1;
	}
	ensureConfigDir();
	saveCredentials(cfg.user, cfg.password);
	version (Windows)
		writeln("Saved credentials (Windows DPAPI) under ", configDir());
	else
		writeln("Saved credentials (mode 0600) under ", configDir());
	if (clearPasswordDrop())
		writeln("Removed password drop file ", passwordDropPath());
	writeln("Logged in to ", cfg.registryUrl, " as ", cfg.user);
	return 0;
}

string requirePackage(string root, string packageName)
{
	if (!packageName.length)
		packageName = readPackageName(root);
	enforceMsg(packageName.length > 0, "Package name required (--package or dub recipe in --root)");
	return packageName;
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

int cmdRegister(PublishConfig cfg, string root, string url, string packageName,
	bool ignoreFork, bool dryRun)
{
	if (!url.length)
		url = detectGitRemoteUrl("origin", root);
	enforceMsg(url.length > 0,
		"No repository URL — pass --url or run inside a git repo with an origin remote");

	auto name = packageName.length ? packageName : readPackageName(root);
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

	bool already = false;
	try
		client.registerPackage(url, ignoreFork);
	catch (AlreadyRegisteredException e)
	{
		already = true;
		writeln("Already registered: ", e.msg);
	}

	if (name.length)
	{
		import core.thread : Thread;
		import core.time : seconds;
		if (!already)
			Thread.sleep(5.seconds);
		foreach (attempt; 0 .. 12)
		{
			if (client.packageExists(name))
			{
				auto upd = client.triggerUpdate(name);
				writeln(already ? "Refreshing existing package." : "Registered.");
				writeln("Update queued (HTTP ", upd.status, ")");
				auto ver = client.latestVersion(name);
				writeln("Latest: ", ver.length ? ver : "(pending)");
				writeln(cfg.registryUrl, "/packages/", name);
				return upd.ok ? 0 : 1;
			}
			if (attempt < 11)
			{
				writeln("Waiting for registry to ingest package… (", attempt + 1, "/12)");
				Thread.sleep(10.seconds);
			}
		}
		writeln(already
			? "Already registered, but package name was not found — check the root recipe name."
			: "Submitted, but package never appeared. Check My packages and recipe name at repo root.");
		writeln(cfg.registryUrl, "/packages/", name);
		writeln(cfg.registryUrl, "/my_packages");
		return 1;
	}

	writeln(already
		? "Already registered. Check " ~ cfg.registryUrl ~ "/my_packages"
		: "Submitted. Check " ~ cfg.registryUrl ~ "/my_packages");
	return 0;
}

int cmdUpdate(PublishConfig cfg, string root, string packageName, string secret, bool dryRun)
{
	packageName = requirePackage(root, packageName);
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
	packageName = requirePackage(root, packageName);
	if (dryRun)
	{
		writeln("Would check status of ", packageName, " on ", cfg.registryUrl);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	if (!client.packageExists(packageName))
	{
		writeln(packageName, ": not found on ", cfg.registryUrl);
		return 1;
	}
	auto ver = client.latestVersion(packageName);
	writeln(packageName, ": ", ver.length ? ver : "(registered, no versions yet)");
	writeln(cfg.registryUrl, "/packages/", packageName);
	return 0;
}

int cmdRemove(PublishConfig cfg, string root, string packageName, bool yes, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	if (!yes && !dryRun)
	{
		stderr.writeln("Refusing to remove '", packageName, "' without --yes");
		return 2;
	}
	if (dryRun)
	{
		writeln("Would remove package ", packageName, " from ", cfg.registryUrl);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.removePackage(packageName);
	writeln("Removed ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

int cmdLogo(PublishConfig cfg, string root, string packageName, string logoPath, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	enforceMsg(logoPath.length > 0, "--logo-file PATH is required");
	if (dryRun)
	{
		writeln("Would upload logo ", logoPath, " for ", packageName);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.setLogo(packageName, logoPath);
	writeln("Logo uploaded for ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

int cmdLogoDelete(PublishConfig cfg, string root, string packageName, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	if (dryRun)
	{
		writeln("Would delete logo for ", packageName);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.deleteLogo(packageName);
	writeln("Logo reset for ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

int cmdDocsUrl(PublishConfig cfg, string root, string packageName, string docsUrl, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	enforceMsg(docsUrl.length > 0, "--docs-url URL is required (use empty string to clear via \"\")");
	if (dryRun)
	{
		writeln("Would set documentation URL for ", packageName, " to ", docsUrl);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.setDocumentationUrl(packageName, docsUrl);
	writeln("Documentation URL updated for ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

int cmdCategories(PublishConfig cfg, string root, string packageName, string[] categories, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	enforceMsg(categories.length > 0, "Pass one or more --category ID (max 4)");
	enforceMsg(categories.length <= 4, "At most 4 categories");
	if (dryRun)
	{
		writeln("Would set categories for ", packageName, ": ", categories.join(", "));
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.setCategories(packageName, categories);
	writeln("Categories updated for ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

int cmdHooks(PublishConfig cfg, string root, string packageName, string secretOut,
	string hooksOut, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	if (dryRun)
	{
		writeln("Would enable/regenerate webhooks for ", packageName);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto secret = client.regenSecret(packageName);
	auto hooks = buildWebhookUrls(cfg.registryUrl, packageName, secret);

	writeln("Webhook secret (shown once):");
	writeln(secret);
	writeln();
	writeln("Generic POST:  ", hooks.generic);
	writeln("GitHub webhook:", hooks.github);
	writeln("GitLab webhook:", hooks.gitlab);
	writeln("(GitLab: set X-Gitlab-Token to the secret in the GitLab webhook UI)");

	if (!secretOut.length)
		secretOut = buildPath(configDir(), "hooks", packageName ~ ".secret");
	mkdirRecurse(dirName(secretOut));
	write(secretOut, secret ~ "\n");
	writeln();
	writeln("Saved secret to ", secretOut);

	if (!hooksOut.length)
		hooksOut = buildPath(configDir(), "hooks", packageName ~ ".hooks.txt");
	mkdirRecurse(dirName(hooksOut));
	auto text = "generic=" ~ hooks.generic ~ "\n"
		~ "github=" ~ hooks.github ~ "\n"
		~ "gitlab=" ~ hooks.gitlab ~ "\n"
		~ "secret_file=" ~ secretOut ~ "\n";
	write(hooksOut, text);
	writeln("Saved webhook URLs to ", hooksOut);
	return 0;
}

int cmdHooksDisable(PublishConfig cfg, string root, string packageName, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	if (dryRun)
	{
		writeln("Would disable webhooks for ", packageName);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.unsetSecret(packageName);
	writeln("Webhooks disabled for ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

int cmdRepo(PublishConfig cfg, string root, string packageName, string kind, string owner,
	string project, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	enforceMsg(kind.length && owner.length && project.length,
		"--kind, --owner, and --project are required");
	if (dryRun)
	{
		writeln("Would set repository for ", packageName, " to ", kind, "/", owner, "/", project);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.setRepository(packageName, kind, owner, project);
	writeln("Repository updated for ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

uint parsePermFlags(string[] flags)
{
	uint perms;
	foreach (f; flags)
	{
		auto key = f.strip.toLower;
		switch (key)
		{
		case "update":
			perms |= 1u << 0;
			break;
		case "metadata", "meta":
			perms |= 1u << 1;
			break;
		case "source", "repo", "repository":
			perms |= 1u << 2;
			break;
		case "admin":
			perms |= (1u << 3) | 0b111;
			break;
		default:
			throw new Exception("Unknown --perm value: " ~ f
				~ " (use update|metadata|source|admin)");
		}
	}
	return perms;
}

int cmdPermsAdd(PublishConfig cfg, string root, string packageName, string username,
	string[] permFlags, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	enforceMsg(username.length > 0, "--username is required");
	auto perms = parsePermFlags(permFlags);
	enforceMsg(perms != 0, "Pass at least one --perm update|metadata|source|admin");
	if (dryRun)
	{
		writeln("Would add ", username, " to ", packageName, " with perms ", perms);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.addSharedUser(packageName, username, perms);
	writeln("Shared user added for ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

int cmdLeave(PublishConfig cfg, string root, string packageName, bool dryRun)
{
	packageName = requirePackage(root, packageName);
	if (dryRun)
	{
		writeln("Would leave package ", packageName);
		return 0;
	}
	auto client = new DubRegistryClient(cfg);
	client.login();
	auto res = client.leavePackage(packageName);
	writeln("Left package ", packageName, " (HTTP ", res.status, ")");
	return res.ok ? 0 : 1;
}

void enforceMsg(bool cond, string msg)
{
	import std.exception : enforce;
	enforce(cond, msg);
}

void printHelp()
{
	writeln(`dub-publish — manage packages on the DUB registry (code.dlang.org)

Automates owner actions that the website exposes under My packages.

Usage:
  # Agent-friendly default drop file (deleted after successful save):
  #   Windows: %LOCALAPPDATA%\dlang-supplemental\dub-publish\password.incoming
  #   Unix:    ~/.dlang-supplemental/dub-publish/password.incoming
  dub-publish login --user NAME --save-credentials
  dub-publish login --user NAME --password PASS [--save-credentials]
  dub-publish login --user NAME --password-file PATH [--save-credentials]
  dub-publish login --user NAME --prompt-password [--save-credentials]
  dub-publish logout
  dub-publish version
  dub-publish register|publish [options]
  dub-publish update|status [options]
  dub-publish remove --yes [options]
  dub-publish logo --logo-file PATH [options]
  dub-publish logo-delete [options]
  dub-publish docs-url --docs-url URL [options]
  dub-publish categories --category ID [--category ID...] [options]
  dub-publish hooks [--secret-out FILE] [--hooks-out FILE] [options]
  dub-publish hooks-disable [options]
  dub-publish repo --kind github --owner ORG --project REPO [options]
  dub-publish perms-add --username NAME --perm update|metadata|source|admin [options]
  dub-publish leave [options]

Common options:
  --registry URL       Registry base URL (default https://code.dlang.org)
  --user, -u NAME      Username or email (env: DUB_REGISTRY_USER)
  --password, -p PASS  Password (env: DUB_REGISTRY_PASSWORD). Appears in shell history
                       and process lists — prefer password.incoming or --password-file.
  --password-file PATH Read password from file (first line)
  --prompt-password    Interactive TTY prompt (no echo); opt-in, not default
  --url URL            Repository URL (default: git remote origin)
  --package, -n NAME   Package name (default: from dub.json / dub.sdl)
  --secret SECRET      Webhook secret for unauthenticated update
  --root DIR           Package directory (default: .)
  --ignore-fork        Allow registering a forked repository
  --dry-run            Print actions only
  --save-credentials   Store user/password locally; consumes password.incoming then deletes it
  --yes, -y            Confirm destructive actions
  -h, --help           Show this help

Credentials:
  Write the password (first line) to password.incoming under the config dir, then:
    dub-publish login --user NAME --save-credentials
  That stores DPAPI (Windows) / mode 0600 (elsewhere) credentials and deletes the
  drop file. Or pass --password / --password-file. -p is visible in ps / history;
  dub-publish does not log it. logout clears the store and any leftover drop file.
  Windows config: %LOCALAPPDATA%\dlang-supplemental\dub-publish\

Notes:
  Logo: png/jpeg/gif/bmp, max 1 MiB, dimensions 2x2..2048x2048 (registry resizes to <=512).
  hooks builds clean webhook URLs (works around dub-registry #614 malformed ?secret= URLs).
  Secret is printed once, then saved under %LOCALAPPDATA%\dlang-supplemental\dub-publish\hooks\
`);
}
