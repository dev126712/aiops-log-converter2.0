// ============================================================
// mongo-init/01_init.js
// Runs once on first container boot to create the aiops DB,
// collections, and a scoped application user.
// ============================================================

db = db.getSiblingDB("aiops");

// Create app-level user with least-privilege access
db.createUser({
  user: "aiops",
  pwd:  "changeme_in_prod",      // overridden by MONGO_PASSWORD in .env
  roles: [
    { role: "readWrite", db: "aiops" }
  ]
});

// Pre-create collections so indexes apply immediately
db.createCollection("anomalies");
db.createCollection("pipeline_runs");

// Index anomalies by detection time for fast range queries
db.anomalies.createIndex({ detected_at: -1 });
db.anomalies.createIndex({ "level_score": 1, "cpu_severity": 1 });

print("✓ aiops database initialised");
