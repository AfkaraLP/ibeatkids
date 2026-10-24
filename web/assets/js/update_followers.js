fetch('api/youtube')
    .then(response => response.json())
    .then(data => {
        document.getElementById('youtube_subs').innerText = data.subscriptionsText;
    });
fetch('api/twitter')
    .then(response => response.json())
    .then(data => {
        document.getElementById('twitter_subs').innerText = data.followersText;
    });
fetch('api/twitch')
    .then(response => response.json())
    .then(data => {
        document.getElementById('twitch_subs').innerText = data.followersText;
    });

document.getElementById('youtube_placeholder').onclick = function changeContent() {
    fetch('api/youtube/latestvideo')
        .then(response => response.json())
        .then(data => {
            document.getElementById('youtube_placeholder').style = "display: none";
            document.getElementById('youtube_embed').style = "display: block";
            document.getElementById('youtube_embed').src = `https://www.youtube.com/embed/${data.id}?autoplay=1`;
        });
}

fetch('api/youtube/latestvideo')
    .then(response => response.json())
    .then(data => {
        document.getElementById('yt_placeholder').src = `${data.thumbnail}`;
        document.getElementById('youtube_viewcount').innerText = data.viewCountText;
        document.getElementById('youtube_stamp').innerText = data.published;
    });