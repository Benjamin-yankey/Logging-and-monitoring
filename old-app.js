require("./tracing"); // Initialize OpenTelemetry
const express = require("express");
const client = require("prom-client");
const helmet = require("helmet");
const rateLimit = require("express-rate-limit");
const { body, param, validationResult } = require("express-validator");
const cors = require("cors");
const xss = require("xss");
const { logInfo, logError } = require("./logger"); // Structured logging
const app = express();
const cspFormActionOrigins = (process.env.CSP_FORM_ACTION_ORIGINS || "")
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);

// Deployment metadata for visibility in metrics and UI
const deploymentTime = new Date().toISOString();
const version = process.env.APP_VERSION || "1.0.0";

// ─── Prometheus Setup ────────────────────────────────────────────────────────
// The Registry is where all our metrics are collected for the /metrics endpoint
const register = new client.Registry();

// Adds: process_cpu_seconds_total, process_resident_memory_bytes,
//       nodejs_eventloop_lag_seconds, nodejs_active_handles,
//       nodejs_active_requests, nodejs_heap_size_*, nodejs_gc_duration_seconds
client.collectDefaultMetrics({
  register,
  labels: { app: "obs-todo-app", version },
});

// ─── Existing Metrics ────────────────────────────────────────────────────────
const httpRequestDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "status_code"],
  // More granular buckets for a fast app (ms range)
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [register],
});

const httpRequestTotal = new client.Counter({
  name: "http_requests_total",
  help: "Total number of HTTP requests",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

const httpErrorsTotal = new client.Counter({
  name: "http_errors_total",
  help: "Total number of HTTP errors",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

const httpRequestCpuTime = new client.Counter({
  name: "http_request_cpu_seconds_total",
  help: "CPU time consumed by HTTP requests",
  labelNames: ["method", "route", "status_code"],
  registers: [register],
});

// ─── NEW: Todo List Business Metrics ────────────────────────────────────────

// Tracks total todos created
const todoCreatedTotal = new client.Counter({
  name: "todo_created_total",
  help: "Total number of todo items created",
  labelNames: ["priority"],
  registers: [register],
});

// Tracks total todos completed
const todoCompletedTotal = new client.Counter({
  name: "todo_completed_total",
  help: "Total number of todo items completed",
  labelNames: ["priority"],
  registers: [register],
});

// Tracks total todos deleted
const todoDeletedTotal = new client.Counter({
  name: "todo_deleted_total",
  help: "Total number of todo items deleted",
  labelNames: [],
  registers: [register],
});

// Gauge: current number of todos in memory (snapshot at any moment)
const todoCountActive = new client.Gauge({
  name: "todo_active_current",
  help: "Current number of active (incomplete) todo items",
  registers: [register],
});

const todoCountCompleted = new client.Gauge({
  name: "todo_completed_current",
  help: "Current number of completed todo items",
  registers: [register],
});

// Histogram: distribution of todos per category
const todoCountByCategory = new client.Gauge({
  name: "todo_count_by_category",
  help: "Number of todos grouped by category",
  labelNames: ["category"],
  registers: [register],
});

// ─── NEW: Request Size Metrics ───────────────────────────────────────────────

const httpRequestSizeBytes = new client.Histogram({
  name: "http_request_size_bytes",
  help: "Size of HTTP request bodies in bytes",
  labelNames: ["method", "route"],
  buckets: [100, 500, 1000, 5000, 10000],
  registers: [register],
});

const httpResponseSizeBytes = new client.Histogram({
  name: "http_response_size_bytes",
  help: "Size of HTTP response bodies in bytes",
  labelNames: ["method", "route", "status_code"],
  buckets: [100, 500, 1000, 5000, 10000, 50000],
  registers: [register],
});

// ─── NEW: Concurrent Requests Gauge ─────────────────────────────────────────

const httpRequestsInFlight = new client.Gauge({
  name: "http_requests_in_flight",
  help: "Number of HTTP requests currently being processed",
  labelNames: ["method", "route"],
  registers: [register],
});

// ─── Helper Functions ───────────────────────────────────────────────────────
let requestCount = 0;
const todos = [];
let nextTodoId = 1;
const todoCategories = ["work", "personal", "shopping", "health", "other"];
const todoPriorities = ["low", "medium", "high"];

function getAllTodos() {
  return [...todos].sort(
    (a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime(),
  );
}

function getTodoById(id) {
  return todos.find((todo) => todo.id === id);
}

function getTodoMetrics() {
  const completed = todos.filter((todo) => todo.completed === 1).length;
  const active = todos.length - completed;
  return { active, completed, total: todos.length };
}

function getActiveCategoryCount(category) {
  return todos.filter(
    (todo) => todo.category === category && todo.completed === 0,
  ).length;
}

function getActivePriorityCount(priority) {
  return todos.filter(
    (todo) => todo.priority === priority && todo.completed === 0,
  ).length;
}

function getDateOnly(value) {
  if (!value) return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString().split("T")[0];
}

// ─── Middleware ───────────────────────────────────────────────────────────────
app.use((req, res, next) => {
  helmet({
    contentSecurityPolicy: false,
    hsts: false,
    crossOriginOpenerPolicy: false,
    originAgentCluster: false,
  })(req, res, next);
});

app.use(
  cors({
    origin: process.env.ALLOWED_ORIGINS?.split(",") || [
      "http://localhost:3000",
      "http://localhost:5000",
    ],
    methods: ["GET", "POST", "PUT", "DELETE"],
    credentials: true,
    maxAge: 86400,
  }),
);

const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  message: "Too many requests from this IP, please try again later.",
  standardHeaders: true,
  legacyHeaders: false,
});

const strictLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  message: "Too many requests from this IP, please try again later.",
  standardHeaders: true,
  legacyHeaders: false,
});

app.use("/api/", limiter);

app.use(express.json({ limit: "10kb" }));
app.use(express.urlencoded({ extended: true, limit: "10kb" }));
app.use(express.static("public"));

// ─── Observability Middleware ───────────────────────────────────────────────
// This middleware runs on every request to track metrics and log traffic
app.use((req, res, next) => {
  requestCount++;
  const timestamp = new Date().toISOString();
  logInfo(`${req.method} ${req.path} - Request #${requestCount}`, {
    method: req.method,
    path: req.path,
    requestNum: requestCount,
  });

  const start = Date.now();
  const cpuStart = process.cpuUsage();

  // Track request body size
  const requestSize = parseInt(req.headers["content-length"] || "0", 10);

  // Increment in-flight gauge
  const routeKey = req.path;
  httpRequestsInFlight.labels(req.method, routeKey).inc();

  res.on("finish", () => {
    const duration = (Date.now() - start) / 1000;
    const cpuEnd = process.cpuUsage(cpuStart);
    const cpuTime = (cpuEnd.user + cpuEnd.system) / 1000000;
    const route = req.route ? req.route.path : req.path;

    // Decrement in-flight
    httpRequestsInFlight.labels(req.method, routeKey).dec();

    // Core metrics
    httpRequestDuration
      .labels(req.method, route, res.statusCode)
      .observe(duration);
    httpRequestTotal.labels(req.method, route, res.statusCode).inc();
    httpRequestCpuTime.labels(req.method, route, res.statusCode).inc(cpuTime);

    // Error tracking
    if (res.statusCode >= 400) {
      httpErrorsTotal.labels(req.method, route, res.statusCode).inc();
    }

    // Request/response size tracking
    if (requestSize > 0) {
      httpRequestSizeBytes.labels(req.method, route).observe(requestSize);
    }
    const responseSize = parseInt(res.getHeader("content-length") || "0", 10);
    if (responseSize > 0) {
      httpResponseSizeBytes
        .labels(req.method, route, res.statusCode)
        .observe(responseSize);
    }
  });

  next();
});

async function updateTodoMetrics() {
  try {
    const { active, completed } = getTodoMetrics();
    todoCountActive.set(active);
    todoCountCompleted.set(completed);

    for (const category of todoCategories) {
      todoCountByCategory
        .labels(category)
        .set(getActiveCategoryCount(category));
    }
  } catch (err) {
    logError("Failed to update todo metrics", { error: err.message });
  }
}

// ─── Routes ───────────────────────────────────────────────────────────────────

// Root route: Serves the interactive Todo List frontend
app.get("/", (req, res) => {
  logInfo("Home page accessed");
  res.send(`
<!DOCTYPE html>
<html>
<head>
    <title>Todo List App - CI/CD Demo</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%); min-height: 100vh; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); }
        h1 { color: #11998e; margin-top: 0; }
        .status { color: #28a745; font-weight: bold; font-size: 18px; }
        .info { background: #f8f9fa; padding: 15px; border-radius: 8px; margin: 20px 0; border-left: 4px solid #11998e; }
        .form-group { margin: 15px 0; }
        label { display: block; margin-bottom: 5px; font-weight: bold; color: #333; }
        input, select { width: 100%; padding: 10px; border: 2px solid #e0e0e0; border-radius: 6px; font-size: 14px; }
        button { background: #11998e; color: white; padding: 12px 30px; border: none; border-radius: 6px; cursor: pointer; font-size: 16px; font-weight: bold; }
        button:hover { background: #0d7a6f; }
        .todo-list { margin-top: 30px; }
        .todo-item { background: #f8f9fa; padding: 15px; margin: 10px 0; border-radius: 8px; border-left: 4px solid #11998e; display: flex; align-items: center; justify-content: space-between; }
        .todo-item.completed { border-left-color: #6c757d; opacity: 0.7; }
        .todo-item.completed .todo-text { text-decoration: line-through; }
        .todo-checkbox { width: 20px; height: 20px; margin-right: 15px; cursor: pointer; }
        .todo-text { flex-grow: 1; }
        .todo-priority { padding: 4px 8px; border-radius: 4px; font-size: 12px; font-weight: bold; margin-right: 10px; }
        .priority-high { background: #dc3545; color: white; }
        .priority-medium { background: #ffc107; color: black; }
        .priority-low { background: #28a745; color: white; }
        .todo-due { font-size: 12px; color: #666; margin-right: 10px; }
        .todo-due.overdue { color: #dc3545; font-weight: bold; }
        .todo-due.soon { color: #ffc107; font-weight: bold; }
        .delete-btn { background: #dc3545; padding: 8px 15px; font-size: 14px; }
        .delete-btn:hover { background: #c82333; }
        .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 15px; margin: 20px 0; }
        .stat-card { background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%); color: white; padding: 20px; border-radius: 8px; text-align: center; }
        .stat-value { font-size: 32px; font-weight: bold; }
        .stat-label { font-size: 14px; opacity: 0.9; }
        .tabs { display: flex; margin-bottom: 20px; border-bottom: 2px solid #e0e0e0; }
        .tab { padding: 10px 20px; cursor: pointer; border: none; background: none; font-size: 16px; color: #666; }
        .tab.active { color: #11998e; border-bottom: 2px solid #11998e; font-weight: bold; }
    </style>
</head>
<body>
    <script>
        // Force HTTP if the browser tries to upgrade to HTTPS
        if (window.location.protocol === 'https:') {
            window.location.href = window.location.href.replace('https:', 'http:');
        }
    </script>
    <div class="container">
        <h1>Todo List</h1>
        <p class="status">System Online</p>
        
        <div class="form-group" style="margin-bottom: 20px;">
            <input type="text" id="searchInput" placeholder="Search todos by task or description..." style="width: 100%; padding: 10px; border: 2px solid #e0e0e0; border-radius: 6px; font-size: 14px;">
        </div>
        
        <div class="stats">
            <div class="stat-card">
                <div class="stat-value" id="activeTodos">0</div>
                <div class="stat-label">Active</div>
            </div>
            <div class="stat-card">
                <div class="stat-value" id="completedTodos">0</div>
                <div class="stat-label">Completed</div>
            </div>
            <div class="stat-card">
                <div class="stat-value">${requestCount}</div>
                <div class="stat-label">API Requests</div>
            </div>
        </div>

        <div class="info">
            <p><strong>Version:</strong> ${version}</p>
            <p><strong>Deployed:</strong> ${deploymentTime}</p>
            <p><strong>Server Time:</strong> ${new Date().toLocaleString()}</p>
        </div>

        <h2>Add New Todo</h2>
        <form id="todoForm">
            <div class="form-group">
                <label>Task</label>
                <input type="text" id="task" placeholder="What needs to be done?" required>
            </div>
            <div class="form-group">
                <label>Description (optional)</label>
                <input type="text" id="description" placeholder="Add more details...">
            </div>
            <div class="form-group">
                <label>Category</label>
                <select id="category" required>
                    <option value="work" selected>Work</option>
                    <option value="personal">Personal</option>
                    <option value="shopping">Shopping</option>
                    <option value="health">Health</option>
                    <option value="other">Other</option>
                </select>
            </div>
            <div class="form-group">
                <label>Priority</label>
                <select id="priority" required>
                    <option value="low">Low</option>
                    <option value="medium" selected>Medium</option>
                    <option value="high">High</option>
                </select>
            </div>
            <div class="form-group">
                <label>Due Date (optional)</label>
                <input type="date" id="dueDate">
            </div>
            <button type="submit">Add Todo</button>
        </form>

        <div class="tabs">
            <button class="tab active" onclick="filterTodos(event, 'all')">All</button>
            <button class="tab" onclick="filterTodos(event, 'active')">Active</button>
            <button class="tab" onclick="filterTodos(event, 'completed')">Completed</button>
        </div>

        <div class="todo-list">
            <div id="todos"></div>
        </div>
    </div>

    <script>
        let currentFilter = 'all';
        let allTodos = [];

        async function loadTodos(search = '') {
            try {
                let url = '/api/todos';
                if (search) {
                    const params = new URLSearchParams();
                    params.set('search', search);
                    url += '?' + params.toString();
                }
                
                const response = await fetch(url);
                const data = await response.json();
                
                allTodos = data.todos;
                document.getElementById('activeTodos').textContent = data.active;
                document.getElementById('completedTodos').textContent = data.completed;
                renderTodos(data.todos);
            } catch (err) {
                console.error('Load Error:', err);
            }
        }

        function renderTodos(todos) {
            const filtered = currentFilter === 'all' ? todos : 
                            currentFilter === 'active' ? todos.filter(t => t.completed === 0) :
                            todos.filter(t => t.completed === 1);
            
            const html = filtered.map(t => {
                let dueDateHtml = '';
                if (t.dueDate) {
                    const due = new Date(t.dueDate);
                    const today = new Date();
                    today.setHours(0, 0, 0, 0);
                    const dueDateOnly = new Date(due.getFullYear(), due.getMonth(), due.getDate());
                    const diffDays = Math.ceil((dueDateOnly - today) / (1000 * 60 * 60 * 24));
                    
                    let dueClass = 'todo-due';
                    if (t.completed === 0 && diffDays < 0) dueClass += ' overdue';
                    else if (t.completed === 0 && diffDays <= 2) dueClass += ' soon';
                    
                    const dateStr = due.toLocaleDateString();
                    const label = diffDays < 0 ? 'Overdue' : diffDays === 0 ? 'Today' : diffDays === 1 ? 'Tomorrow' : dateStr;
                    dueDateHtml = '<span class="' + dueClass + '">' + label + '</span>';
                }
                
                const descHtml = t.description ? '<div style="font-size: 12px; color: #666; margin-top: 5px;">' + t.description + '</div>' : '';
                
                return '<div class="todo-item ' + (t.completed ? 'completed' : '') + '">' +
                    '<input type="checkbox" class="todo-checkbox" ' + (t.completed ? 'checked' : '') + ' onchange="toggleTodo(' + t.id + ')">' +
                    '<div style="flex-grow: 1;">' +
                    '<span class="todo-text">' + t.task + '</span>' +
                    descHtml +
                    '</div>' +
                    dueDateHtml +
                    '<span class="todo-priority priority-' + t.priority + '">' + t.priority + '</span>' +
                    '<button class="delete-btn" onclick="deleteTodo(' + t.id + ')">Delete</button>' +
                '</div>';
            }).join('');
            document.getElementById('todos').innerHTML = html || '<p>No todos yet</p>';
        }

        function filterTodos(event, filter) {
            currentFilter = filter;
            document.querySelectorAll('.tab').forEach(tab => tab.classList.remove('active'));
            event.target.classList.add('active');
            loadTodos();
        }

        document.getElementById('todoForm').onsubmit = async (e) => {
            e.preventDefault();
            const dueDateValue = document.getElementById('dueDate').value;
            const data = {
                task: document.getElementById('task').value,
                category: document.getElementById('category').value,
                priority: document.getElementById('priority').value,
                description: document.getElementById('description').value || '',
                dueDate: dueDateValue || null
            };
            try {
                const response = await fetch('/api/todos', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(data)
                });
                const result = await response.json();
                if (!response.ok) {
                    alert('Error: ' + (result.errors ? result.errors.map(e => e.msg).join(', ') : result.error || 'Failed to create todo'));
                    return;
                }
                e.target.reset();
                document.getElementById('category').value = 'work';
                loadTodos();
            } catch (err) {
                alert('Error: ' + err.message);
            }
        };

        async function toggleTodo(id) {
            try {
                await fetch('/api/todos/' + id + '/toggle', {
                    method: 'PUT',
                    headers: {'Content-Type': 'application/json'}
                });
                loadTodos();
            } catch (err) {
                console.error('Toggle Error:', err);
            }
        }

        async function deleteTodo(id) {
            try {
                await fetch('/api/todos/' + id, {
                    method: 'DELETE',
                    headers: {'Content-Type': 'application/json'}
                });
                loadTodos();
            } catch (err) {
                console.error('Delete Error:', err);
            }
        }

        document.getElementById('searchInput').addEventListener('input', (e) => {
            loadTodos(e.target.value);
        });

        loadTodos();
        setInterval(() => loadTodos(), 5000);
    </script>
</body>
</html>
    `);
});

app.get("/api/todos", (req, res) => {
  try {
    const { search, category, priority, completed } = req.query;
    let allTodos = getAllTodos();

    if (search) {
      const searchTerm = String(search).toLowerCase();
      allTodos = allTodos.filter((todo) => {
        const task = String(todo.task || "").toLowerCase();
        const description = String(todo.description || "").toLowerCase();
        return task.includes(searchTerm) || description.includes(searchTerm);
      });
    }
    if (category) {
      allTodos = allTodos.filter((todo) => todo.category === category);
    }
    if (priority) {
      allTodos = allTodos.filter((todo) => todo.priority === priority);
    }
    if (completed !== undefined) {
      const completedValue = completed === "true" ? 1 : 0;
      allTodos = allTodos.filter((todo) => todo.completed === completedValue);
    }

    const { active, completed: completedCount, total } = getTodoMetrics();

    logInfo("Fetching todos", {
      count: allTodos.length,
      filters: { search, category, priority },
    });
    res.json({
      total: total,
      active: active,
      completed: completedCount,
      todos: allTodos,
    });
  } catch (err) {
    logError("Failed to fetch todos", { error: err.message });
    res.status(500).json({ success: false, error: "Failed to fetch todos" });
  }
});

app.post(
  "/api/todos",
  [
    body("task")
      .trim()
      .notEmpty()
      .isLength({ max: 500 })
      .withMessage("Task is required and must be less than 500 characters"),
    body("description")
      .optional()
      .trim()
      .isLength({ max: 2000 })
      .withMessage("Description must be less than 2000 characters"),
    body("category")
      .trim()
      .notEmpty()
      .isIn(["work", "personal", "shopping", "health", "other"])
      .withMessage("Invalid category"),
    body("priority")
      .optional()
      .isIn(["low", "medium", "high"])
      .withMessage("Invalid priority"),
    body("dueDate")
      .optional()
      .isISO8601()
      .toDate()
      .withMessage("Invalid due date"),
    strictLimiter,
  ],
  (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ success: false, errors: errors.array() });
    }

    const { task, description, category, priority, dueDate } = req.body;
    const now = new Date().toISOString();

    try {
      const entry = {
        id: nextTodoId++,
        task: xss(task),
        description: description ? xss(description) : null,
        category: xss(category),
        priority: priority || "medium",
        dueDate: getDateOnly(dueDate),
        completed: 0,
        completedAt: null,
        createdAt: now,
        updatedAt: now,
      };

      todos.push(entry);

      todoCreatedTotal.labels(priority || "medium").inc();
      updateTodoMetrics();

      logInfo(`Todo created: ${task}`, {
        priority: priority || "medium",
        category,
        id: entry.id,
      });
      res.json({ success: true, entry });
    } catch (err) {
      logError("Failed to create todo", { error: err.message });
      res.status(500).json({ success: false, error: "Failed to create todo" });
    }
  },
);

app.put(
  "/api/todos/:id/toggle",
  [param("id").isInt({ min: 1 }).withMessage("Invalid todo ID")],
  (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ success: false, errors: errors.array() });
    }

    const id = parseInt(req.params.id);

    try {
      const todo = getTodoById(id);

      if (!todo) {
        return res
          .status(404)
          .json({ success: false, error: "Todo not found" });
      }

      const wasCompleted = todo.completed === 1;
      const newCompleted = wasCompleted ? 0 : 1;
      const completedAt = newCompleted ? new Date().toISOString() : null;
      const now = new Date().toISOString();

      todo.completed = newCompleted;
      todo.completedAt = completedAt;
      todo.updatedAt = now;

      if (newCompleted && !wasCompleted) {
        todoCompletedTotal.labels(todo.priority || "medium").inc();
      }
      updateTodoMetrics();

      logInfo(`Todo toggled: ${todo.task}`, {
        completed: newCompleted === 1,
      });
      res.json({ success: true, todo });
    } catch (err) {
      logError("Failed to toggle todo", { error: err.message });
      res.status(500).json({ success: false, error: "Failed to toggle todo" });
    }
  },
);

app.delete(
  "/api/todos/:id",
  [param("id").isInt({ min: 1 }).withMessage("Invalid todo ID"), strictLimiter],
  (req, res) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
      return res.status(400).json({ success: false, errors: errors.array() });
    }

    const id = parseInt(req.params.id);

    try {
      const todoIndex = todos.findIndex((todo) => todo.id === id);

      if (todoIndex === -1) {
        return res
          .status(404)
          .json({ success: false, error: "Todo not found" });
      }

      const [deletedTodo] = todos.splice(todoIndex, 1);

      todoDeletedTotal.inc();
      updateTodoMetrics();

      logInfo(`Todo deleted: ${deletedTodo.task}`, { id });
      res.json({ success: true });
    } catch (err) {
      logError("Failed to delete todo", { error: err.message });
      res.status(500).json({ success: false, error: "Failed to delete todo" });
    }
  },
);

app.get("/api/info", (req, res) => {
  try {
    const { active, completed, total } = getTodoMetrics();
    logInfo("System info requested");
    res.json({
      version,
      deploymentTime,
      status: "running",
      totalTodos: total,
      activeTodos: active,
      completedTodos: completed,
      totalRequests: requestCount,
    });
  } catch (err) {
    logError("Failed to get system info", { error: err.message });
    res.status(500).json({ error: "Failed to get system info" });
  }
});

app.get("/api/stats", (req, res) => {
  try {
    const stats = {
      byCategory: {},
      byPriority: {},
      overdue: 0,
    };

    for (const category of todoCategories) {
      stats.byCategory[category] = getActiveCategoryCount(category);
    }

    for (const priority of todoPriorities) {
      stats.byPriority[priority] = getActivePriorityCount(priority);
    }

    const today = new Date().toISOString().split("T")[0];
    stats.overdue = todos.filter((todo) => {
      if (todo.completed !== 0 || !todo.dueDate) return false;
      const dueDate = getDateOnly(todo.dueDate);
      return dueDate !== null && dueDate < today;
    }).length;

    res.json(stats);
  } catch (err) {
    logError("Failed to get stats", { error: err.message });
    res.status(500).json({ error: "Failed to get statistics" });
  }
});

app.get("/health", (req, res) => {
  logInfo("Health check performed");
  res.status(200).json({
    status: "healthy",
    uptime: process.uptime(),
    timestamp: new Date().toISOString(),
  });
});

app.get("/metrics", async (req, res) => {
  res.set("Content-Type", register.contentType);
  res.end(await register.metrics());
});

if (require.main === module) {
  const port = process.env.PORT || 5000;
  app.listen(port, "0.0.0.0", () => {
    logInfo(`Server running on port ${port}`);
  });
}

module.exports = app;
