const workouts = {
	"Day 1": ["High Bar Squat", "Bench Press", "GHD"],
	"Day 2": ["Low Bar Squat", "Deadlift", "DB Press"],
	"Day 3": ["Goblet Squat", "Pushups", "Lunges"]
};

function loadWorkout() {
	const select = document.getElementById("workout-select");
	const container = document.getElementById("sets-container");
	container.innerHTML = "";
	const exercises = workouts[select.value] || [];
	exercises.forEach(ex => {
		const label = document.createElement("label");
		label.textContent = ex;
		container.appendChild(label);
		for (let i = 1; i <= 3; i++) {
			const row = document.createElement("div");
			row.className = "set-row";
			["Load", "Reps", "RPE"].forEach(field => {
				const input = document.createElement("input");
				input.placeholder = `${field} Set ${i}`;
				input.type = "number";
				input.dataset.exercise = ex;
				input.dataset.set = i;
				input.dataset.field = field;
				const key = `${ex}-set${i}-${field}`;
				input.value = localStorage.getItem(key) || "";
				input.oninput = () => localStorage.setItem(key, input.value);
				row.appendChild(input);
			});
			container.appendChild(row);
		}
	});
}

document.addEventListener("DOMContentLoaded", () => {
	loadWorkout();

    document.getElementById("workout-select").addEventListener("click", () => {
		loadWorkout();
	});
});
