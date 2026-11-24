// The `preversion` and `postversion` hooks of `npm version`, so that a release is
// one command that bumps package.json and its lockfile, commits, tags and pushes:
//
//     npm version patch        # or minor, major, 0.4.0-beta.1
//
// `check` runs before anything is written. It refuses unless HEAD is main and
// level with origin/main, and the new tag exists neither here nor on origin:
// npm commits before it tags, so a tag that already exists would otherwise
// leave a stray version commit behind. `push` sends the commit and the tag in
// one atomic push, which starts `.github/workflows/release.yml`.

import { execFileSync } from 'node:child_process';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();

function fail(message) {
	console.error(`release: ${message}`);
	process.exit(1);
}

const version = process.env.npm_new_version;
if (!version) fail('run this through `npm version <patch|minor|major|x.y.z>`, not directly');
const tag = `v${version}`;

const mode = process.argv[2];
if (mode === 'check') {
	const branch = git('rev-parse', '--abbrev-ref', 'HEAD');
	if (branch !== 'main') fail(`on ${branch}; release from main`);

	git('fetch', '--quiet', 'origin', 'main');
	if (git('rev-parse', 'HEAD') !== git('rev-parse', 'origin/main')) {
		fail('main and origin/main differ; pull or push first');
	}

	if (git('tag', '--list', tag)) fail(`tag ${tag} already exists locally`);
	if (git('ls-remote', '--tags', 'origin', `refs/tags/${tag}`)) {
		fail(`tag ${tag} already exists on origin`);
	}
} else if (mode === 'push') {
	execFileSync('git', ['push', '--atomic', 'origin', 'HEAD:main', tag], { stdio: 'inherit' });
} else {
	fail(`unknown mode ${mode}; expected check or push`);
}
