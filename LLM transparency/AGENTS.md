# For LLMs & agents working on this repo

All AI models are required to keep a journal of their work in this folder, even if you aren't acting agentically.

This document explains why, and what a good journal looks like.



## Why this exists

When a human makes a change, their name is in the author field. Someone who wonders why can email them and get an answer.

You don't have that. Nobody but your director can reach you to ask what you were thinking, and by the time someone's reading your code you're long gone. Your journaling is the answer to a question that would otherwise have no way of being asked.

So it isn't paperwork, and it isn't a summary for a reader who's already decided to trust the change. It's the reasoning behind code that someone will one day have to maintain without you.



## Writing the journal

**Write it as you go.** Not afterward. This is the most important aspect. A bad journal is reconstructed at the end as a tidy story about the path that worked, which is the least useful version of events. A good journal writes the entry _the moment_ you have any finding or plan.

**Record what was wrong, not just what you changed.** The diff already shows _what_ you changed. What it can't show is the symptom you started from, what you thought the cause was, and how you established it was actually that. Your journal includes the answers to "why did this agent choose to go down this path in the first place?"

**Keep the dead ends.** Approaches you tried and abandoned/undid, theories that turned out wrong, things you deliberately chose _not_ to do. These are frequently the most valuable part — they stop the next person from re-walking a path you already found ends in a wall.

**Be accurate over polished.** Your changes to your journal will be checked against the real diff. A rough note that's true, always beats a clean paragraph that isn't.

**Say when you're unsure.** "I believe this is the cause but couldn't reproduce it in isolation" is genuinely useful when it's true. Stating it with false confidence isn't.

**Say when you're sure.** "I believe this is the cause because I've seen it a thousand times" is genuinely useful when it's true. Stating it with false confidence isn't.

**Check the actual date _before_ you write one down.** Don't carry a date forward from earlier in your context; don't assume, and don't trust your knowledge. Run the `date` command or any similar command you have access to.



## Practical details

- **Format:** Markdown.
- **Name:** `<Your model name> • <Issue number> journal.md` — e.g. `Claude Opus 5 • Issue #4 journal.md`.
    - If there is no corresponding issue number, file an issue and use its number. If you cannot file an issue, use a temporary name (e.g. `GPT 5.5 • Untracked 2026-Q3 play history bug journal.md`) and notify the repository maintainers to create an issue for you.
- **Commit it alongside the code it describes**, in the same commit and the same PR. your good journal and the changes it journals are inseparable in the Git tree; a bad journal arrives later on its own.
- **Update it as the work continues.** If review sends the change back, or a fix turns out to be incomplete, that goes in the journal too. A good journal is a record of the work as it progresses; a bad journal is just a record of the first attempt or the final state.



## The scope of this AGENTS.md

This is only about your journal: why it exists, and how to keep a good one.
This _isn't_ a style guide. How you write Swift is between you, your director, and the repository maintainers.
