module dub_publish.github_hooks;

import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, remove, tempDir, write;
import std.json : JSONValue, parseJSON;
import std.path : buildPath;
import std.process : execute;
import std.string : strip;

import dub_publish.git;

/// Result of creating or updating a GitHub repository webhook.
struct GithubHookResult
{
	bool ok;
	bool skipped;
	string message;
	long hookId;
}

/// code.dlang.org's `/update/github` endpoint only queues an update on `create`
/// (new tags/branches). Other events return HTTP 200 `"ignored event …"`.
enum string[] dubGithubHookEvents = ["create"];

/// Create or update a GitHub webhook that points at the DUB GitHub update URL.
GithubHookResult installGithubDubHook(string repoUrl, string hookUrl, bool dryRun)
{
	GithubHookResult result;
	string owner, repo;
	if (!parseGithubOwnerRepo(repoUrl, owner, repo))
	{
		result.skipped = true;
		result.message = "origin is not a GitHub repo; skipped GitHub webhook install";
		return result;
	}

	if (dryRun)
	{
		result.ok = true;
		result.message = "Would install GitHub webhook on " ~ owner ~ "/" ~ repo
			~ " → " ~ hookUrl ~ " (events: create)";
		return result;
	}

	auto gh = execute(["gh", "--version"]);
	if (gh.status != 0)
	{
		result.message = "gh not found on PATH; install GitHub CLI or create the webhook manually:\n"
			~ "  gh api --method POST repos/" ~ owner ~ "/" ~ repo
			~ "/hooks --input - <<< '" ~ hookPayload(hookUrl) ~ "'";
		return result;
	}

	auto existingId = findDubHookId(owner, repo);
	if (existingId != 0)
	{
		auto patch = patchHook(owner, repo, existingId, hookUrl);
		if (!patch.ok)
			return patch;
		patch.message = "Updated GitHub webhook #" ~ existingId.to!string
			~ " on " ~ owner ~ "/" ~ repo ~ " (events: create)";
		return patch;
	}

	return createHook(owner, repo, hookUrl);
}

private GithubHookResult createHook(string owner, string repo, string hookUrl)
{
	auto run = ghApiJson(["--method", "POST", "repos/" ~ owner ~ "/" ~ repo ~ "/hooks"],
		hookPayload(hookUrl));
	GithubHookResult result;
	if (run.status != 0)
	{
		result.message = "gh api POST hooks failed:\n" ~ run.output.strip;
		return result;
	}
	try
	{
		auto json = parseJSON(run.output);
		result.hookId = json["id"].integer;
		result.ok = true;
		result.message = "Created GitHub webhook #" ~ result.hookId.to!string
			~ " on " ~ owner ~ "/" ~ repo ~ " (events: create)";
	}
	catch (Exception)
	{
		result.ok = true;
		result.message = "Created GitHub webhook on " ~ owner ~ "/" ~ repo;
	}
	return result;
}

private GithubHookResult patchHook(string owner, string repo, long id, string hookUrl)
{
	auto run = ghApiJson(["--method", "PATCH",
			"repos/" ~ owner ~ "/" ~ repo ~ "/hooks/" ~ id.to!string],
		hookPayload(hookUrl));
	GithubHookResult result;
	result.hookId = id;
	if (run.status != 0)
	{
		result.message = "gh api PATCH hooks/" ~ id.to!string ~ " failed:\n" ~ run.output.strip;
		return result;
	}
	result.ok = true;
	return result;
}

private long findDubHookId(string owner, string repo)
{
	auto run = execute(["gh", "api", "repos/" ~ owner ~ "/" ~ repo ~ "/hooks"]);
	if (run.status != 0)
		return 0;
	try
	{
		foreach (hook; parseJSON(run.output).array)
		{
			auto url = hook["config"]["url"].str;
			if (url.canFind("code.dlang.org/api/packages/")
				&& url.canFind("/update/github"))
				return hook["id"].integer;
		}
	}
	catch (Exception)
	{
	}
	return 0;
}

private auto ghApiJson(string[] apiArgs, string jsonBody)
{
	auto path = buildPath(tempDir, "dub-publish-github-hook.json");
	write(path, jsonBody);
	auto run = execute(["gh", "api"] ~ apiArgs ~ ["--input", path]);
	if (exists(path))
		remove(path);
	return run;
}

private string hookPayload(string hookUrl)
{
	JSONValue cfg;
	cfg["url"] = hookUrl;
	cfg["content_type"] = "json";
	cfg["insecure_ssl"] = "0";
	JSONValue payload;
	payload["name"] = "web";
	payload["active"] = true;
	payload["events"] = JSONValue(dubGithubHookEvents);
	payload["config"] = cfg;
	return payload.toString();
}
