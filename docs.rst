********
smplcmts
********

A simple comment system for websites.

Why?
####

I had spent more time than expected researching and trying out self-hosted website comment systems until I realized that my time would be better spent writing one that I would actually want to use. Here's what I realized I want:

* No 3rd-party anything, including authentication
* No cookie banner
* Minimal friction in usage
* Mindful of privacy and security
* Extremely light on resource usage
* Adapts to web site style
* Easy to find in search engines

smplcmts is all of those things.

* Authentication is done over email
* But it's not saved, and no secret user data is collected- no banner requirement
* No password is used, drafts are autosaved, messages and replies are displayed flat with context like in a whatsapp or signal group chat
* No secret data whatsoever is stored but you still can't post as someone else
* The backend uses about 20MB of memory, unoptimized, the frontend is 2.5kB, unminified, uncompressed
* The comments become part of ordinary web site content and can be styled
* The comments are properly indexed by Google and can be placed directly into HTML for other search engines

Installation
############

# todo

Usage
#####

# todo

Security
########

**Authentication**

smplcmts uses only emailed tokens for the login, which is equivalent in security to a password system with a reset feature. On successful
auth a session token is provided to the client as a HTTPOnly-Cookie.

Very long tokens are used that are meant to be clicked on as part of a URL. Providing an invalid token results in an IP ban of three seconds and auth tokens expire. This is plenty of delay to make a brute force attack
extremely unlikely to succeed without imposing noticable limitations on users as an escalalting scheme would. Distributed brute force attacks are still unlikely to succeed due to key length, and key length can easily be increased further if required.

**Identity**

A unique identity is tied to a unique email address. A user is discouraged to but still can produce multiple accounts. Spam scripts do not work due to email verification requirement. There is no protection from more sophisticated bot account registration who possess an email address, although this might be added later.

**Networking**

The service is expected to be run behind a reverse proxy that takes care of SSL termination, DOS attacks, and potentially distributed brute force attacks.

Limitations
###########

* Currently, there is no moderation tool- if you want to moderate a post, you go to the database and replace the text with the words "deleted by moderator". This is sufficient for a start but likely to change in the future.
* No third party authentication schemes are supported on purpose because this is a fully self-hosted tool.
* Comment threads are not supported by design because in the view of smplcmts web site comments are supposed to reply to the article, not discuss finer points in detail in sub discussions as one would with a forum. Therefore, a group chat model is provided that reminds of whatsapp (we don't like the data collection but we like the interface) or perhaps a very, very simplified discourse (but without reply quotes). Manual reply quoting remains possible for the determined.
* Extensive markup and imagery are not supported on purpose in order not to distract from the main article. This *might* change.

Desirable features
##################

* Simple, flexible moderation tool- show all comments in a stream and allow filtering by site, user
* paging for really really huge comment threads
* Configurability for all user-visible messages
* Possibly bot account registration protection as long as it does not use captchas which tend to be third-party or ineffective

