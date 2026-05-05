// Local publisher: POST events to the notification-service over HTTP.
// In GCP, swap this for a Pub/Sub publisher (@google-cloud/pubsub).
const NOTIFICATION_URL = process.env.NOTIFICATION_URL || 'http://notification-service:8080/events';

async function publish(event) {
  try {
    const res = await fetch(NOTIFICATION_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(event),
    });
    if (!res.ok) {
      console.error(`publish failed: ${res.status} ${await res.text()}`);
    }
  } catch (err) {
    console.error(`publish error: ${err.message}`);
  }
}

module.exports = { publish };
