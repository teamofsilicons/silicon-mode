Silicon Mode is a native Mac app that allows users to put their mac on Silicon Mode when agents are running in the background and the mac is half closed.

[cs = configurable setting]

this uses the mac's lid tilt sensor (many projects using this sensor already, see for reference) to detect the angle of a user's mac, and if it becomes lower than 75deg (cs) and agents are running in the background then it enters "Silicon Mode"

# Silicon Mode:
this is like a screensaver, but cooler. it first of all caffinates the system to prevent it from sleeping (also a configurable toggle), then it displays Silicon Mode Faces (we'll have 5 defaults, and then an entire marketplace of these).

## How to Enter:
When mac's lid angle < 75deg, it starts a 5sec (cs) timer which is displayed as an overlay with progressive blur from the top showing that its counting down with a button saying "Do not enter Silicon Mode" at right corner while the timer is in the middle of the blur. this does not move around but is similar to the blur iphone duo has, except the perspective change.

Then after the timer is done, we shoot in the silicon mode face. default silicon mode face, or the face the person has set. this animation is like the apple's animation when iphones are bumped to share contacts.

Only start counting once the lid angle is stable, and once we enter into silicon mode, that becomes our silicon mode angle.

## Inside Silicon Mode:
For one minute, it does not lock disabling. so the user can disable and turn silicon mode turns off until the user returns back to the normal position (>75deg) for more than 1min (cs).

this way if a person has this app installed but can still use the mac in low tilt while lying down and until we're sure that the user is back up for more than 1min, we dont accidentally turn on silicon mode again and again.

when silicon mode is active for more than 1min, then it does not turn off by itself even when the lid is back up. then a person can exit silicon mode by clicking so and entering a 6 digit pin they have saved when setting up the app.

there should also be a way to enter with fingerprint, but that is for if the person does not remember the 6 digit code. this is also setup during the intitial setup of the app.

i am doing this because i think as an app, asking for fingerprint seems more sketchy as a mac pop up shows up. but if it can be done without the pop up, happy to have fingerprint as the default way.
«
## Silicon Mode Faces
It can know which all agents are running & how many. Then it can use that to make cool faces. Say a pacman style eating, or a 3d animation, or claude code mascot using computer, or anything really...

A DVD style bounce off the edges would be cool for the agents. Maybe it can have logos of all the companies that are being run right now.

Anything infinite, and long is a good candidate.

Think of 5 great faces we can have. Perhaps it can also show a clock.

Different faces can give different kinds of customization.

## Exiting Silicon Mode
We do not automatically end silicon mode ever. once its active, its always by turning it off by the user and entering the pin.

## Panic Mode
If agents are running and the mac is being closed after entering silicon mode... it enters panic mode. here, a panic mode sound + visual appears. it flashes rapidly to get the attention of the person who's closing it, and optionally (by default yes) a sound is played which is like error, or mistake, or something like that. we can give options for both panic mode face and sound. we'll have to do good sound design here. learn from bencho sounds. https://bencho.dev/sounds

It is triggered when the new angle is < 0.9 * Silicon Mode angle.

It does not play anything when opening. It also doesn't play anything if the mac was closed and then opened again later. Only when closing.

## Agents
Make it compatible with as many providers as possible. claude code, codex, grok, antigravity, opencode, pi, connected silicons, running hermes, openclaw etc etc

We detect & connect automatically to agent sessions running when silicon mode is on, and read it to give stats on the page like 3 agents need you, or 4 agents finished, and 2 agents working.

We should also show a little preview of the last 5-10 events from the agent(s). Or questions that agents have that can be answered from the agent mode itself.

It should be configurable if they wanna show tail 10 logs, and/or questions when silicon mode is active. if they even wanna see the list of agents working, or how many are working.

all of them are turned on by default but can be turned off.

## Menu Bar & Shortcut
There should be a menu bar icon, and a keyboard shortcut (ctrl + option + s) to enter into silicon mode even with the lid open. Even without silicon mode active, a person can click on the menu bar icon and see which all agents are running, if any is waiting for a reply from this user and they can also answer directly from the menu bar.

we'll have to design the menu bar app very well as well. similar to https://gethoy.app/

## Authentication
It doesn't require login to do most things, but to use marketplace faces, or to use mobile device, they can authenticate via silicon accounts. This is an interface which doesn't use any silcon app. https://interfaces.teamofsilicons.com/

This mac is logged into si:tos for you to build things.
creds: ~/code/silicon-browser/target/release-tools/private/tos-silicon.json

## Local Silicon
(to be added later, rn anon silicons are not possible) We will implement an annonymus silicon so that people can make custom faces for their agents, and even write new rules to detect their custom harness and agents.

Later custom made faces can be published and used by others in the community.


## Mobile App & Desktop App
People can login to their mobile phones, and see stats of them using agents, how often they use agents, how long do they run, and if rn silicon mode is active or not. If it is, then it shows then the tailed logs (even if turned off to show on mac), questions/permissions they can answer directly from their phone.

They can see their stats on the desktop app as well if they open it.

We can show a 24 hour vertical column and each day add one more column to show how often are they running agents and how many are being run in a given hour. overtime, people can see their patterns of when they run agents and how many, how many days do they skip, etc etc.

This can be made into a webapp as well where people can see their silicon mode status, see logs and answer questions. once this is working.
then iphone & android app, also native.
android is connected to this mac to test things out.
it is possible to have more than one mac connected to the same account, so keep them separate.

## Backend
Use Silicon Cell for backend.

## URL
mode.teamofsilicons.com

## Problems
If you're running into any problem with the silicon ecosystem, note them down and keep a track of it, all of it is open source so go and find out why and make a PR with the fixes if you you can find them.

## Design Style:
Use native liquid glass as much as possible.

Use native mac's style + Silicon Accounts, with Allo Font with the same config as Silicon Accounts. https://github.com/teamofsilicons/silicon-accounts

Get the colors and all from here as well. this is our style.

We need incredibly creative animations for this app to work well and sit with people.
We need it to feel snappy and responsive.