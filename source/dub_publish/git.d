module dub_publish.git;

import std.algorithm : canFind, startsWith;
import std.array : appender, split;
import std.exception : enforce;
import std.process : Redirect, pipeProcess, wait;
import std.string : strip, chomp;

/// Return the URL for a git remote (default `origin`), or null if unavailable.
string detectGitRemoteUrl(string remote = "origin", string cwd = ".")
{
	// Keep git's "not a repository" noise off the user's terminal.
	auto pipes = pipeProcess(["git", "-C", cwd, "remote", "get-url", remote],
		Redirect.stdout | Redirect.stderr);
	auto outBuf = appender!string();
	foreach (chunk; pipes.stdout.byChunk(4096))
		outBuf.put(cast(char[]) chunk);
	foreach (chunk; pipes.stderr.byChunk(4096))
	{
		// drain stderr
	}
	auto status = wait(pipes.pid);
	if (status != 0)
		return null;
	auto url = outBuf.data.strip;
	if (!url.length)
		return null;
	return normalizeRepoUrl(url);
}

/// Turn common git remote forms into an https URL the registry accepts.
string normalizeRepoUrl(string url)
{
	url = url.strip;
	url = url.chomp(".git");

	// git@github.com:owner/repo
	if (url.startsWith("git@"))
	{
		auto rest = url[4 .. $]; // host:path
		auto colon = rest.indexOfColon();
		enforce(colon >= 0, "Unrecognized SSH remote: " ~ url);
		auto host = rest[0 .. colon];
		auto path = rest[colon + 1 .. $];
		return "https://" ~ host ~ "/" ~ path;
	}

	// ssh://git@host/owner/repo
	if (url.startsWith("ssh://"))
	{
		auto without = url["ssh://".length .. $];
		if (without.canFind("@"))
			without = without.split("@")[1];
		return "https://" ~ without;
	}

	if (!url.startsWith("http://") && !url.startsWith("https://"))
	{
		// github.com/owner/repo or owner/repo shorthand → assume github
		if (url.canFind("/"))
		{
			if (url.canFind("."))
				return "https://" ~ url;
			return "https://github.com/" ~ url;
		}
	}

	return url;
}

private ptrdiff_t indexOfColon(string s)
{
	foreach (i, c; s)
		if (c == ':')
			return cast(ptrdiff_t) i;
	return -1;
}
