<?php
/**
 * Vibe Check Stats Dashboard
 *
 * Displays conversation statistics and charts
 */

error_reporting(E_ALL);
ini_set('display_errors', 1);
ini_set('log_errors', 1);

// Load configuration
$config = json_decode(file_get_contents(__DIR__ . '/config.json'), true);

// Database connection
$mysqli = new mysqli(
    $config['mysql']['host'],
    $config['mysql']['user'],
    $config['mysql']['password'],
    $config['mysql']['database']
);

if ($mysqli->connect_error) {
    die("Database connection failed: " . $mysqli->connect_error);
}

$mysqli->set_charset('utf8mb4');

// Query 1: Get total prompts and average character length
// Filter for user messages directly in MySQL using JSON functions
$stats_query = "
    SELECT
        COUNT(*) as total_prompts,
        AVG(
            CHAR_LENGTH(
                COALESCE(
                    JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.message.content[0].text')),
                    JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.message.content'))
                )
            )
        ) as avg_chars
    FROM conversation_events
    WHERE JSON_EXTRACT(event_data, '$.type') = 'user'
";

$result = $mysqli->query($stats_query);
$stats = $result->fetch_assoc();
$total_prompts = (int)$stats['total_prompts'];
$avg_chars = round($stats['avg_chars'], 1);

// Query 2: Get daily message counts
// Group by date extracted from JSON timestamp
$daily_query = "
    SELECT
        DATE(JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.timestamp'))) as msg_date,
        COUNT(*) as msg_count
    FROM conversation_events
    WHERE JSON_EXTRACT(event_data, '$.type') = 'user'
        AND JSON_EXTRACT(event_data, '$.timestamp') IS NOT NULL
    GROUP BY msg_date
    ORDER BY msg_date ASC
";

$result = $mysqli->query($daily_query);
$daily_counts = [];
while ($row = $result->fetch_assoc()) {
    $daily_counts[$row['msg_date']] = (int)$row['msg_count'];
}

// Query 3: Get monthly message counts
$monthly_query = "
    SELECT
        DATE_FORMAT(JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.timestamp')), '%Y-%m') as msg_month,
        COUNT(*) as msg_count
    FROM conversation_events
    WHERE JSON_EXTRACT(event_data, '$.type') = 'user'
        AND JSON_EXTRACT(event_data, '$.timestamp') IS NOT NULL
    GROUP BY msg_month
    ORDER BY msg_month ASC
";

$result = $mysqli->query($monthly_query);
$monthly_counts = [];
while ($row = $result->fetch_assoc()) {
    $monthly_counts[$row['msg_month']] = (int)$row['msg_count'];
}

// Query 4: Get daily message counts per project
// Extract project from file_name (first segment before slash, or whole filename)
$project_daily_query = "
    SELECT
        DATE(JSON_UNQUOTE(JSON_EXTRACT(event_data, '$.timestamp'))) as msg_date,
        SUBSTRING_INDEX(file_name, '/', 1) as project,
        COUNT(*) as msg_count
    FROM conversation_events
    WHERE JSON_EXTRACT(event_data, '$.type') = 'user'
        AND JSON_EXTRACT(event_data, '$.timestamp') IS NOT NULL
    GROUP BY msg_date, project
    ORDER BY msg_date ASC, project ASC
";

$result = $mysqli->query($project_daily_query);
$project_data = [];
$all_projects = [];
$all_dates = array_keys($daily_counts); // Reuse dates from overall daily counts

while ($row = $result->fetch_assoc()) {
    $date = $row['msg_date'];
    $project = $row['project'];
    $count = (int)$row['msg_count'];

    if (!isset($project_data[$project])) {
        $project_data[$project] = [];
        $all_projects[] = $project;
    }

    $project_data[$project][$date] = $count;
}

// Fill in missing dates with 0 for each project
foreach ($project_data as $project => &$dates) {
    foreach ($all_dates as $date) {
        if (!isset($dates[$date])) {
            $dates[$date] = 0;
        }
    }
    ksort($dates); // Sort by date
}

$mysqli->close();

// Calculate averages
$num_days = count($daily_counts);
$num_months = count($monthly_counts);

$avg_per_day = $num_days > 0 ? round($total_prompts / $num_days, 1) : 0;
$avg_per_month = $num_months > 0 ? round($total_prompts / $num_months, 1) : 0;

// Prepare chart data (already sorted from MySQL)
$chart_labels = json_encode(array_keys($daily_counts));
$chart_data = json_encode(array_values($daily_counts));

?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Vibe Check Stats</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #0f1419;
            color: #e6edf3;
            padding: 2rem;
            line-height: 1.6;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
        }

        h1 {
            font-size: 2.5rem;
            margin-bottom: 0.5rem;
            background: linear-gradient(135deg, #6366f1 0%, #a855f7 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
        }

        .subtitle {
            color: #8b949e;
            margin-bottom: 3rem;
            font-size: 1.1rem;
        }

        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 1.5rem;
            margin-bottom: 3rem;
        }

        .stat-card {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 12px;
            padding: 1.5rem;
            transition: transform 0.2s, border-color 0.2s;
        }

        .stat-card:hover {
            transform: translateY(-2px);
            border-color: #6366f1;
        }

        .stat-label {
            color: #8b949e;
            font-size: 0.875rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 0.5rem;
        }

        .stat-value {
            font-size: 2.5rem;
            font-weight: 700;
            color: #e6edf3;
            line-height: 1;
        }

        .stat-unit {
            color: #8b949e;
            font-size: 1rem;
            margin-left: 0.25rem;
        }

        .chart-container {
            background: #161b22;
            border: 1px solid #30363d;
            border-radius: 12px;
            padding: 2rem;
            margin-bottom: 2rem;
        }

        .chart-title {
            font-size: 1.25rem;
            margin-bottom: 1.5rem;
            color: #e6edf3;
        }

        canvas {
            max-height: 400px;
        }

        .footer {
            text-align: center;
            color: #6e7681;
            margin-top: 3rem;
            padding-top: 2rem;
            border-top: 1px solid #30363d;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Vibe Check Stats</h1>
        <p class="subtitle">Conversation analytics dashboard</p>

        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-label">Total Prompts</div>
                <div class="stat-value"><?php echo number_format($total_prompts); ?></div>
            </div>

            <div class="stat-card">
                <div class="stat-label">Avg Message Length</div>
                <div class="stat-value"><?php echo number_format($avg_chars); ?><span class="stat-unit">chars</span></div>
            </div>

            <div class="stat-card">
                <div class="stat-label">Avg Per Day</div>
                <div class="stat-value"><?php echo $avg_per_day; ?><span class="stat-unit">msgs</span></div>
            </div>

            <div class="stat-card">
                <div class="stat-label">Avg Per Month</div>
                <div class="stat-value"><?php echo $avg_per_month; ?><span class="stat-unit">msgs</span></div>
            </div>
        </div>

        <div class="chart-container">
            <h2 class="chart-title">Message Volume Over Time</h2>
            <canvas id="volumeChart"></canvas>
        </div>

        <div class="chart-container">
            <h2 class="chart-title">Message Volume by Project</h2>
            <canvas id="projectChart"></canvas>
        </div>

        <div class="footer">
            Last updated: <?php echo date('Y-m-d H:i:s'); ?>
        </div>
    </div>

    <script>
        const ctx = document.getElementById('volumeChart').getContext('2d');

        new Chart(ctx, {
            type: 'line',
            data: {
                labels: <?php echo $chart_labels; ?>,
                datasets: [{
                    label: 'Messages per Day',
                    data: <?php echo $chart_data; ?>,
                    borderColor: '#6366f1',
                    backgroundColor: 'rgba(99, 102, 241, 0.1)',
                    borderWidth: 2,
                    fill: true,
                    tension: 0.4,
                    pointRadius: 4,
                    pointHoverRadius: 6,
                    pointBackgroundColor: '#6366f1',
                    pointBorderColor: '#fff',
                    pointBorderWidth: 2
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                plugins: {
                    legend: {
                        display: false
                    },
                    tooltip: {
                        mode: 'index',
                        intersect: false,
                        backgroundColor: 'rgba(22, 27, 34, 0.95)',
                        titleColor: '#e6edf3',
                        bodyColor: '#8b949e',
                        borderColor: '#30363d',
                        borderWidth: 1,
                        padding: 12,
                        displayColors: false
                    }
                },
                scales: {
                    x: {
                        grid: {
                            color: '#30363d',
                            drawBorder: false
                        },
                        ticks: {
                            color: '#8b949e',
                            maxRotation: 45,
                            minRotation: 45
                        }
                    },
                    y: {
                        beginAtZero: true,
                        grid: {
                            color: '#30363d',
                            drawBorder: false
                        },
                        ticks: {
                            color: '#8b949e',
                            precision: 0
                        }
                    }
                },
                interaction: {
                    mode: 'nearest',
                    axis: 'x',
                    intersect: false
                }
            }
        });

        // Project Chart - Multiple lines for different projects
        const projectCtx = document.getElementById('projectChart').getContext('2d');

        // Color palette for different projects
        const colors = [
            '#6366f1', '#a855f7', '#ec4899', '#f59e0b', '#10b981',
            '#06b6d4', '#8b5cf6', '#f97316', '#14b8a6', '#84cc16'
        ];

        // Build datasets for each project
        const projectDatasets = [
            <?php
            $color_index = 0;
            foreach ($project_data as $project => $dates) {
                $color = $color_index % 10; // Cycle through colors
                $data_values = json_encode(array_values($dates));
                echo "{
                    label: " . json_encode($project) . ",
                    data: $data_values,
                    borderColor: colors[$color],
                    backgroundColor: 'transparent',
                    borderWidth: 2,
                    tension: 0.4,
                    pointRadius: 3,
                    pointHoverRadius: 5,
                    pointBackgroundColor: colors[$color],
                    pointBorderColor: '#fff',
                    pointBorderWidth: 1
                }";
                if ($color_index < count($project_data) - 1) {
                    echo ",\n                ";
                }
                $color_index++;
            }
            ?>
        ];

        new Chart(projectCtx, {
            type: 'line',
            data: {
                labels: <?php echo $chart_labels; ?>,
                datasets: projectDatasets
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                plugins: {
                    legend: {
                        display: true,
                        position: 'top',
                        labels: {
                            color: '#e6edf3',
                            padding: 12,
                            font: {
                                size: 11
                            },
                            usePointStyle: true
                        }
                    },
                    tooltip: {
                        mode: 'index',
                        intersect: false,
                        backgroundColor: 'rgba(22, 27, 34, 0.95)',
                        titleColor: '#e6edf3',
                        bodyColor: '#8b949e',
                        borderColor: '#30363d',
                        borderWidth: 1,
                        padding: 12
                    }
                },
                scales: {
                    x: {
                        grid: {
                            color: '#30363d',
                            drawBorder: false
                        },
                        ticks: {
                            color: '#8b949e',
                            maxRotation: 45,
                            minRotation: 45
                        }
                    },
                    y: {
                        beginAtZero: true,
                        grid: {
                            color: '#30363d',
                            drawBorder: false
                        },
                        ticks: {
                            color: '#8b949e',
                            precision: 0
                        }
                    }
                },
                interaction: {
                    mode: 'nearest',
                    axis: 'x',
                    intersect: false
                }
            }
        });
    </script>
</body>
</html>
