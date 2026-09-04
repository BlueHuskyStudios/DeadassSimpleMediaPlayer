# LLM transparency

[I, Ky,](https://KyLeggiero.me) reviewed all the code in this repo, and wrote the vast majority of it.

Some of it was written using LLMs, either directly writing it, or assisting contributors like myself.

This folder contains various files which help increase the transparency of that usage.



## Which LLMs were used?

The following is a list of all LLMs used in the creation & maintenance of Deadass Simple Media Player, along with a brief description of what they were used for.

- Claude (directed by @KyNorthstar)
    - 5 Fable - Writing code to unblock Ky, minor feature work 
    - 5 Opus - Writing code to unblock Ky, minor bug work, minor feature work
    - 5 Sonnet - Searches, minor algorithmic decisions
    - 4.8 Opus - Writing code to unblock Ky
- Grok (autonomously on behalf of @VedantMadane)
    - _version undisclosed_ (2026-08-27) - Minor bug work
- GPT (directed by @Zhoie)
    - 5.6 Sol - Minor bug work
- GPT-OSS (directed by @KyNorthstar)
    - _20b_ - Minor algorithmic decisions
- Apple Foundation Models (built into Xcode, used by @KyNorthstar and probably most other contributors as well)
    - _version unknown_ Autocomplete

> For more details on the more notable use, see the journals in this folder.



## Which commits involved LLMs?

Commits with notable LLM usage are marked as "Co-authored by" those LLMs, because transparency matters.
Files written with notable LLM usage are marked as "Written by Ky directing <LLM>" or similar, because _transparency fucking matters._

Tiny shit like autocomplete isn't mentioned anywhere because it's not significant enough to matter.



## How much autonomy were the LLMs given?

None of these LLMs were given direct access to the repo.
None of the code was accepted blindly; check [the PRs](https://github.com/BlueHuskyStudios/DeadassSimpleMediaPlayer/pulls) for proof. **Fuck vibe coding.**

Any time an LLM is asked to do notable work (e.g. implement a minor feature or fix a minor bug all on its own), that LLM is required to keep a Markdown journal of its actions. That journal is then manually checked for accuracy against the changes it performed, and saved in this folder.



## It's fine if you don't like this.

If that all is still a dealbreaker for you, I get it. No hard feelings; go use something that's better for you.
