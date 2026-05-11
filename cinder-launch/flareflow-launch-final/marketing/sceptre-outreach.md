# Sceptre Outreach
# Use whichever contact method you can find:
# - Sceptre Discord → DM a team member or post in #integrations
# - Twitter/X → DM @SceptreFi or whoever runs their account
# - Email if listed on their site
# - Tag them in your launch tweet (lower response rate but still worth doing)
#
# Keep it short. They get a lot of messages. Lead with what's in it for them.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
VERSION A — Discord DM (short, casual)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Hey — I built a yield aggregator on top of sFLR on Flare Network called Cinder.

It auto-compounds sFLR staking rewards for depositors. There's also a one-click zap that lets users stake FLR directly through your staking contract — no manual Sceptre step required.

Thought you might find it useful — more sFLR use cases seems good for both of us. Happy to share the contracts if you want to look.

App: [SITE_URL]
Code: [GITHUB_URL]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
VERSION B — Email or formal DM (more detail)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Subject: Built a yield aggregator on top of sFLR — thought you'd want to know

Hi Sceptre team,

I'm a solo developer who's spent the last few months building Cinder — a yield aggregator for sFLR on Flare Network. It launched on mainnet [DATE].

What it does: users deposit sFLR and receive cFLR vault shares that automatically appreciate as the protocol harvests and re-compounds staking rewards. Depositors also earn EMBER governance tokens on top of the base staking yield.

The part you might find interesting: I built a one-click Zap contract (CinderZap.sol) that lets users deposit native FLR directly. Internally it calls your staking contract's submit() function to get sFLR, then deposits that into the Cinder vault — all in a single transaction. No manual Sceptre step required.

More sFLR demand and use cases seems like a good thing for the ecosystem generally. If you'd consider mentioning Cinder to your community, I'd really appreciate it. Happy to answer any questions about the implementation or share the contracts for review.

App: [SITE_URL]
Contracts: [GITHUB_URL]
Vault address: [VAULT_ADDRESS]

Thanks for building sFLR — it made this possible.

[Your name/handle]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FOLLOW-UP (if no response after 5 days)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Hey — following up on my message about Cinder. TVL has grown to [AMOUNT] in the first week with [NUMBER] depositors. 

The Zap contract has processed [NUMBER] transactions routing FLR through your staking contract. Thought you might find the usage data interesting.

Still happy to chat if there's any interest in a partnership or mutual promotion.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ALSO REACH OUT TO:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Flare Network official team**
Same approach — short message explaining what you built. Ask if they'd share it with the ecosystem. The Flare team actively promotes ecosystem projects on their social channels. One retweet from @FlareNetworks is worth more than 10 paid influencers.

Message template:
"Hey — I built a yield aggregator for sFLR on Flare called Cinder. Auto-compounds staking rewards, has on-chain governance via EMBER token, and a one-click FLR zap. Solo project, open source, live on mainnet. Would love if you'd share it with the community. [SITE_URL]"

**Firelight team**
When you're ready to launch the stXRP vault, reach out to Firelight. Same deal — you're building demand for their product, they should want to tell their community.

**DeFiLlama**
Submit a PR to the DefiLlama-Adapters repo after you have some TVL. This gets you listed and makes you discoverable to the entire DeFi researcher community. The adapter code is already in your repo.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WHAT SUCCESS LOOKS LIKE FROM SCEPTRE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Best case: they tweet about it and mention in their Discord
Good case: they reply warmly but don't formally promote
Neutral: no response (follow up once, then move on)
Bad: they're hostile or ask you to stop using their contract

The last one is very unlikely — you're adding value to their ecosystem. 
But if it happens, the Zap can be reconfigured to use a different 
staking path (Sparkdex WFLR→sFLR swap as fallback).
