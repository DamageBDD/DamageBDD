function formatCell(obj, cell, value, type) {

	if (type === 'start_time' || type === 'end_time') {
		const date = new Date(value * 1000);
		const today = new Date();
		if (date.toDateString() === today.toDateString()) {
			cell.textContent =  date.toLocaleTimeString();
		} else {
			cell.textContent = date.toLocaleString();
		}
	} else if (type === 'execution_time') {
		cell.textContent = `${value} seconds`;
	} else if (type === 'feature_title') {
		const link = document.createElement("a");
		link.href = `/reports/${obj.report_hash}`;
		link.textContent = value;
		link.target = '_blank';
		cell.appendChild(link);
	} else if (type === 'feature_hash') {
		const link = document.createElement("a");
		link.href = `/features/${value}`;
		link.textContent = value;
		link.target = '_blank';
		cell.appendChild(link);
		cell.className = "hash";
	} else if (type === 'report_hash') {
		const link = document.createElement("a");
		link.href = `/reports/${value}`;
		link.textContent = value;
		link.target = '_blank';
		cell.appendChild(link);
		cell.className = "hash";
	} else if (type === 'contract_address') {
		const link = document.createElement("a");
		link.href = `https://www.aeknow.org/index.php/contract/detail/${value}`;
		link.textContent = value;
		link.target = '_blank';
		cell.appendChild(link);
		cell.className = "hash";
	}else{
		cell.textContent = value;
	}
	return cell;
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
				table.className = "pure-table pure-table-horizontal pure-table-striped";
				var headerRow = document.createElement("tr");
				var headers = [
					"",
					"Feature Title",
					"Start Time",
					"End Time",
					"Execution Time",
					"Feature",
					"Report",
					"Contract Address"
				];
				headers.forEach(function(header) {
					var th = document.createElement("th");
					th.textContent = header;
					headerRow.appendChild(th);
				});
				table.appendChild(headerRow);

				// Reverse sorting the results by start_time column
				data.results.sort((a, b) => {
					return new Date(b.start_time) - new Date(a.start_time);
				});

				data.results.forEach(function(obj, i) {
					var row = document.createElement("tr");
					if (i % 2){
						row.className = "pure-table-odd";
					}
					var edit = document.createElement("a");
					
					var cells = [
						"edit",
						"feature_title",
						"start_time",
						"end_time",
						"execution_time",
						"feature_hash",
						"report_hash",
						"contract_address"
					].map(function(prop) {
						var td = document.createElement("td");
						return formatCell(obj, td, obj[prop], prop);
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

