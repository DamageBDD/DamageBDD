// Define a module to handle notifications
const Notifications = (function() {
    let toasts = [];
    
    // Check if there are any existing notifications in local storage and load them
    if(localStorage.getItem('notifications')) {
        toasts = JSON.parse(localStorage.getItem('notifications'));
    }
    
    // Function to notify and store the notification in local storage
    const notify = (title, content, style) => {
        toasts.push({
            title: title,
            content: content,
            style: style
        });
        localStorage.setItem('notifications', JSON.stringify(toasts));
    };
    
    // Function to display notifications in a popdown
    const displayNotifications = () => {
        let html = '<ul>';
        
        toasts.forEach(notification => {
            html += `<li class="${notification.style}"><strong>${notification.title}</strong>: ${notification.content}</li>`;
        });
        
        html += '</ul>';
        
        // Display the notifications in a popdown
        // You can use your own implementation to display notifications
        alert(html);
    };
    
    return {
        notify: notify,
        displayNotifications: displayNotifications
    };
})();

// Example of using the Notifications module
Notifications.notify('Request Failed', 'Feature execution failed.', 'error'); // Call this whenever you want to show a notification
// To display the notifications, call the below function
Notifications.displayNotifications();
