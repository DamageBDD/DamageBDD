function formatCell(value, type) {
    if (type === 'start_time' || type === 'end_time') {
        return new Date(value * 1000).toLocaleString();
    } else if (type === 'execution_time') {
        return `${value} seconds`;
    } else {
        return value;
    }
}

function updateHistoryTable() {
    const request = {
        method: 'POST',
        credentials: 'include',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
            since: "1day"
        })
    };

    fetch("/reports/", request)
        .then(response => {
            if (response.status === 200) {
                return response.json();
            } else if (response.status === 401) {
                MicroModal.show('login-modal');
            } else {
                console.error("Error reports fetching failed: ", response);
            }
        })
        .then(data => {
            if (data && data.status === "ok") {
                var historyDiv = document.getElementById("history");
                var table = document.createElement("table");
                var headerRow = document.createElement("tr");
                var headers = [
                    "Feature Title",
                    "Start Time",
                    "End Time",
                    "Execution Time",
                    "Feature Hash",
                    "Report Hash",
                    "Contract Address"
                ];
                headers.forEach(function(header) {
                    var th = document.createElement("th");
                    th.textContent = header;
                    headerRow.appendChild(th);
                });
                table.appendChild(headerRow);

                data.results.forEach(function(obj) {
                    var row = document.createElement("tr");
                    var cells = [
                        "feature_title",
                        "start_time",
                        "end_time",
                        "execution_time",
                        "feature_hash",
                        "report_hash",
                        "contract_address"
                    ].map(function(prop) {
                        var td = document.createElement("td");
                        td.textContent = formatCell(obj[prop], prop);
                        return td;
                    });

                    cells.forEach(function(cell) {
                        row.appendChild(cell);
                    });

                    table.appendChild(row);
                });

                historyDiv.innerHTML = "";
                historyDiv.appendChild(table);
            } else {}
        });
}
