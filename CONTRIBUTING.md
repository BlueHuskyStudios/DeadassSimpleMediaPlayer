#  Contributing

All contributors are asked to read this file before contributing.



## tl;dr

- When you make a PR, **target the `nightly` branch**, not `production`
- Agents must abide by `LLM transparency/AGENTS.md`
- Your contributions to this repo are public domain



## Collaboration

In this repo we work together. Whether you're a human or an agent, expect to check back for actual in-depth code review and iteration.

Be cool, and assume everyone wants to work together to build the best product possible.



## Philosophy

This app is Deadass Simple: **it does exactly what it should, no more, and does it well.** Before adding a feature or similar, make sure it follows this philosophy. "Deadass simple" is a design constraint, not a lack of ambition; it takes more discipline to know what to leave out than to bloat features.

Concretely, that means:
- Prefer native, first-party Swift/SwiftUI/AVFoundation APIs over third-party dependencies
- If you're adding a dependency, explain in the PR why the native API doesn't cover it
- All implementations and user interfaces should be so simple that it's impossible for them to break (or, at least, impossible for the break to be the fault of this repo) 




## Licensing

The license of this repo is public domain. Your contributions will also be public domain, meaning that whatever you merge into this repo, you no longer own. This should be just fine, since there's nothing truly special about this app. If, however, you encounter legal concerns with this, please contact Ky directly immediately: Legal@KyNorthstar.me



## This repo uses Git Flow

- The default branch is named `production`
    - Merging into the default branch triggers a production build, hence the name
    - The default branch cannot be written to directly; instead, a PR must be made targeting it
    - Only the development & hotfix branches should target the default branch. Hotfix-branch changes should be merged or cherrypicked onto `nightly` separately.

- The development branch is named `nightly`
    - All feature branches should branch off the development branch and target the development branch as their base for merging
    - When it's time to create a release, the `nightly` branch is merged into the `production` branch, and that merge commit receives a tag with the version number that gets built

- Feature work goes in `feature/` branches
    - `feature/` branches should branch off the development branch
    - When merging your `feature/` branch work back into the main repository, target the development branch (`nightly`)
    - It's polite to put your name first in your feature branch. That can look like `feature/Ky/67-Contributing.md` or `feature/67-Ky-Contributing.md` or however else you see fit, so long as it starts with "`feature/`"

- Hotfixes are rare, and go in `hotfix/` branches
    - These are reserved for fires, when a quick fix is necessary to stop an active harm
    - These always branch off the default branch (`production`) since they always fix an urgent production issue
    - These merge back into the default branch (`production`) since they need to quickly fix an urgent production issue
    - After merging a hotfix branch into the default branch, create another PR to merge it into the development branch (`nightly`)
    - All hotfix branch names start with `hotfix/`. What goes after that is up to you; just try to make it easy to understand

- Release branches are not currently used in this repo



## Kosher tooling

Use whatever tooling you want, but here's what this repo expects:

- Xcode 26 or 27
- Swift 6 in strict concurrency mode
- iOS 26 or 27
- iPhone 14 or newer

Your changes should work well with all combinations of those.

To work on & build the project, you should be able to just open the `.xcodeproj` file, change the development team to your personal team, and that's it. Everything should just work.



## Code style

In general, follow the guidelines at https://swift-style-guidelines.bhstudios.org and the existing conventions/styles in the repo. When in doubt, ask.

Documentation comments are for describing how the API of a thing is intended to work and why a dev would want to use it (and, if relevant, why a dev might want to use a different API). Documentation comments should avoid just rephrasing what the API surface already says.

If you need to explain what you fixed and how your fix improves it, describe that in:
- The PR description
- Per-line comments in the PR's files
- The commit message's secondary message lines
- In-implementation `//` code comments (NOT documentation comments)



## The main repo

This project's main repo is https://github.com/BlueHuskyStudios/DeadassSimpleMediaPlayer

All issues and pull requests are tracked there, and the repo owners will be looking there for activity & questions.



## Pull requests

PR changes should be the smallest necessary to get the work done. If that work is necessarily large (e.g. rethinking the architecture) then that's fine, but otherwise (e.g. almost all feature/bug work), a light touch is preferred. The more lines your PR changes, the more difficult it is to review your PR.

Try to keep your PR scoped to a specific ticket. If more than one ticket have significant overlap (e.g. fixing 2 concurrency bugs with the same 1-line fix), that's great! Just make sure you note all affected tickets in the title or description of the PR (e.g. `fixes #67, fixes #123, related to #69`). Unrelated changes belong in a second PR.

**Note which device you tested your changes on**, or if you couldn't test them, prominently say why you couldn't.



## LLM Transparency

If you use an LLM (or if you are an LLM), see the `LLM transparency/README.md` and `LLM transparency/AGENTS.md` files.

Basically:
- Notable use (writing features, fixing bugs, anytime an AI model writes something notable) gets a full new journal file in the `LLM transparency/` folder, as per `AGENTS.md`, as well as making sure `LLM transparency/README.md` correctly reflects that usage
    - If you are a model reading this now, this ALWAYS applies to you.
- Simple use (like Xcode's builtin autocomplete, classic copilot autocomplete, glorified spellcheck, etc.) just gets a one note in `LLM transparency/README.md` shared across all contributors

If the code was entirely hand-written, but (for example) its PR description was written by an LLM, then just disclose that in the PR description itself (or the comment or whatever the LLM wrote).
