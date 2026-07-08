# Barnyard! A connection pooler for your Postgres!

## Note
This is learning software. Don't use this right now (maybe ever). Not only is this meant for learning purposes but also it's not meant to compete right now with any actually mature connection pooler. I just think actors are neat.

## Another pooler???
Actors are pretty cool, and while I've taken the time to learn things like the BEAM, Pony has always been on the list to try out. Well-- now I've tried it and I like what I see!

This project can be viewed as a bit of a ref to the postgres wire protocol which is fairly simple, although I'm not sure this handles all cases just yet.

## AI Usage Disclaimer
I did use Claude for this (kinda hard to hide the CLAUDE.md file even if I wanted to) with some constraints:

- Claude was never allowed to give me direct answers (oh boy did it want to)
- The majority of code written should be written by me at first, then can be refactored via an LLM. This way I know what's roughly happening and I can verify that it's a translation, not a materialization out of the ether
- Since I couldn't get the LSP or linter to run (crashes on nixos for some reason), I allowed fable to rewrite some things to get to a more idiomatic state. It went a bit overboard in places with this

One section where I had to lean on AI a bit more than I would have liked:

I encountered a situation where my performance was something like 2.5x worse than PGBouncer in a similar config. I exhausted my ability to debug the program and had to iterate pretty heavily with the LLM to figure out what was going on. Turns out it was a combination of:

1. Copying bytes
2. Iterating through said bytes to find frame boundaries
3. Not releasing connections back to the pool properly (whoops!)

And weirdly

4. Allowing pony's scheduler to take up all 14 cores of my PC. Dropping to 2 cores max improved perf up to 90% of PGBouncer

This is where a lot of LLM-looking code also came from. Once I got the initial state machine working, I had the LLM refactor to more idiomatic code while also doing perf analysis.

## Things I liked:

1. Pony in general, even though the `iso`, `val`, `ref` dances are a bit hard to grok at times
2. The elegance of the state model that came out of this, with the actor handling the connection, state handling the processing and transitions
3. The postgres wire protocol, pretty straightforward to write a proxy for this.

## Things I didn't like as much but are my fault:

1. My inexperience with Pony caused me to have to guess at performance sinks (the LLM was useless here). Most of the time it did come down to allocations which were relatively easy to pin but at times it was due to runtime tuning or defaults
2. Cap system syntax, although I'm guessing this is mainly due to it being new to my eyes. Something about `recover iso Foo() end` looks odd

## How does this perform?
See bench/results.md for current running results on my laptop.
