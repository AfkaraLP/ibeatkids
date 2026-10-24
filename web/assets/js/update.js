let youtube = null, twitter = null, twitch = null, twitchlive = null;

function cachedOrFetch(key, url) {
    return (async () => {
        let data = null;
        try {
            data = JSON.parse(localStorage.getItem(key));
        } catch (e) {
            try { localStorage.removeItem(key); } catch (_) {}
            data = null;
        }
        if (data && typeof data === "object" && data.time && data.time >= Date.now()) {
            return data;
        }
        try {
            const res = await fetch(url, { cache: "no-store" });
            const fresh = await res.json();
            if (fresh && typeof fresh === "object") {
                data = fresh;
                try { localStorage.setItem(key, JSON.stringify(data)); } catch (_) {}
            }
        } catch (e) {
            // keep whatever cached value exists, even if expired
        }
        return data;
    })();
}

async function updatePage() {
    [youtube, twitter, twitch, twitchlive] = await Promise.all([
        cachedOrFetch("youtube", "api/youtube"),
        cachedOrFetch("twitter", "api/twitter"),
        cachedOrFetch("twitch", "api/twitch"),
        cachedOrFetch("twitchlive", "api/twitch/islive"),
    ]);
    try { if (youtube) updateYoutube(youtube); } catch (e) {}
    try { if (twitter) updateTwitter(twitter); } catch (e) {}
    try { if (twitch) updateTwitch(twitch); } catch (e) {}
    try { if (twitchlive) updateTwitchLive(twitchlive); } catch (e) {}
}

updatePage();

function updateYoutube(data) {
    let youtube_subs = document.getElementById('youtube_subs');
    youtube_subs.innerText = data.channel.subscribersText;
    youtube_subs.classList.toggle("skeleton");
    document.getElementById('yt_placeholder').src = data.video.thumbnail;
    document.getElementById('youtube_viewcount').innerText = data.video.viewsText;
    document.getElementById('youtube_stamp').innerText = data.video.publishedText;
}

function updateTwitter(data) {
    let twitter_subs = document.getElementById('twitter_subs');
    twitter_subs.innerText = data.followersText;
    twitter_subs.classList.toggle("skeleton");
}

function updateTwitch(data) {
    let twitch_subs = document.getElementById('twitch_subs');
    twitch_subs.innerText = data.followersText;
    twitch_subs.classList.toggle("skeleton");
}

function updateTwitchLive(data) {
    let twitchcard = document.getElementById('twitchcard');
    let twitch_subs = document.getElementById('twitch_subs');
    if (data.islive) {
        twitchcard.classList.add("islive");
        twitch_subs.innerText = data.viewers + " Live Viewers"
        document.getElementById("twitchlive").innerText = "🔴 Watch Stream";
    } else {
        twitchcard.classList.remove("islive");
    }
}

document.getElementById('youtube_placeholder').onclick = function () {
    if (!youtube || !youtube.video) return;
    document.getElementById('youtube_placeholder').style = "display: none";
    document.getElementById('youtube_embed').style = "display: block";
    document.getElementById('youtube_embed').src = `https://www.youtube.com/embed/${youtube.video.id}?autoplay=1`;
}