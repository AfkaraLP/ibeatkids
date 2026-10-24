function createnewQuote() {
    fetch('/api/quotes')
        .then(function (response) {
            return response.json();
        })
        .then(function (json) {
            document.getElementById("quote").innerHTML = '"' + json.quote + '"';
        });
}