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
		} else if (type === 'hash') {
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
		} else if (type === 'delete') {
			const link = document.createElement("a");
			link.textContent = type;
			link.onclick = 'deleteSchedule(${value})';
			cell.appendChild(link);
			cell.className = "hash";
		} else if (type === 'clone') {
			const link = document.createElement("a");
			link.textContent = type;
			link.onclick = 'deleteSchedule(${value})';
			cell.appendChild(link);
			cell.className = "hash";
		}else{
			const deletebtn = document.createElement("a");
			cell.textContent = value;
		}
		return cell;
	}
async function updateSchedulesTable() {
	const request = {
		method: 'GET',
		credentials: 'include',
		headers: { 'Content-Type': 'application/json' },
	};

	const response = await fetch("/schedules/", request);
	var data = {};
	if (response.status === 200) {
		data = await response.json();
	} else if (response.status === 401) {
		MicroModal.show('login-modal');
		return
	} else {
		console.error("Error schedules fetching failed: ", response);
		return
	}
	if (data && data.status === "ok") {
		var schedulesDiv = document.getElementById("schedules");
		var table = document.createElement("table");
		var headerRow = document.createElement("tr");
		var headers = [
			"Delete",
			"Clone",
			"Feature Title",
			"CronSpec",
			"Created Time",
            "Last Excution",
            "Execution Counter",
			"Concurrency",
			"Feature Hash",
			"Contract Address",
		];
		headers.forEach(function(header) {
			var th = document.createElement("th");
			th.textContent = header;
			headerRow.appendChild(th);
		});
		table.appendChild(headerRow);

		// Reverse sorting the results by start_time column
		data.results.sort((a, b) => {
			return new Date(b.created) - new Date(a.created);
		});

		data.results.forEach(function(obj) {
			var row = document.createElement("tr");
			var cells = [
			    "delete",
			    "clone",
				"feature_title",
				"cronspec",
				"created",
				"last_execution_timestamp",
				"execution_counter",
				"concurrency",
				"hash",
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

		schedulesDiv.innerHTML = "";
		schedulesDiv.appendChild(table);
	} else {}
}
