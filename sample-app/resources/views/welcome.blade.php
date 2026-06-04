<!DOCTYPE html>
<html lang="en">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>KubeQuest</title>
        <script
            src="https://code.jquery.com/jquery-3.7.0.min.js"
            integrity="sha256-2Pmvv0kuTBOenSvLm6bvfBSSHrUJ+3A7x6P5Ebd07/g="
            crossorigin="anonymous"></script>
        <style>
            :root {
                --bg: #f8fafc;
                --card: #ffffff;
                --border: #e2e8f0;
                --text: #0f172a;
                --muted: #64748b;
                --hover: #f1f5f9;
            }

            * {
                box-sizing: border-box;
            }

            body {
                margin: 0;
                min-height: 100vh;
                display: flex;
                align-items: center;
                justify-content: center;
                padding: 24px;
                background-color: var(--bg);
                color: var(--text);
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI",
                    Roboto, Helvetica, Arial, sans-serif;
                -webkit-font-smoothing: antialiased;
            }

            .card {
                width: 100%;
                max-width: 360px;
                background: var(--card);
                border: 1px solid var(--border);
                border-radius: 12px;
                padding: 32px;
                box-shadow: 0 1px 2px rgba(15, 23, 42, 0.04);
                text-align: center;
            }

            .card__title {
                margin: 0 0 4px;
                font-size: 18px;
                font-weight: 600;
                letter-spacing: -0.01em;
            }

            .card__version {
                margin: 0 0 28px;
                font-size: 12px;
                font-weight: 500;
                color: var(--muted);
            }

            .counter__label {
                margin: 0 0 8px;
                font-size: 12px;
                font-weight: 500;
                text-transform: uppercase;
                letter-spacing: 0.08em;
                color: var(--muted);
            }

            .counter__value {
                margin: 0 0 28px;
                font-size: 56px;
                font-weight: 700;
                line-height: 1;
                font-variant-numeric: tabular-nums;
                letter-spacing: -0.02em;
            }

            .actions {
                display: flex;
                gap: 8px;
                justify-content: center;
            }

            .btn {
                flex: 1;
                appearance: none;
                border: 1px solid var(--border);
                background: var(--card);
                color: var(--text);
                font-size: 14px;
                font-weight: 500;
                padding: 9px 12px;
                border-radius: 8px;
                cursor: pointer;
                transition: background-color 0.12s ease, border-color 0.12s ease;
            }

            .btn:hover {
                background: var(--hover);
            }

            .btn:active {
                background: var(--border);
            }

            .btn:focus-visible {
                outline: 2px solid var(--muted);
                outline-offset: 2px;
            }
        </style>
    </head>
    <body>
        <main class="card">
            <h1 class="card__title">KubeQuest Counter App</h1>
            <p class="card__version">v2</p>

            <p class="counter__label">Counter</p>
            <p class="counter__value" id="value">{{ $value }}</p>

            <div class="actions">
                <button class="btn" id="subtract" type="button">−1</button>
                <button class="btn" id="reset" type="button">Reset</button>
                <button class="btn" id="add" type="button">+1</button>
            </div>
        </main>

        <script>
            $(document).ready(function () {
                function render(data) {
                    $('#value').text(data.value);
                }

                $('#add').click(function () {
                    $.get('/api/counter/add', render);
                });

                $('#subtract').click(function () {
                    $.get('/api/counter/subtract', render);
                });

                $('#reset').click(function () {
                    $.get('/api/counter/reset', render);
                });
            });
        </script>
    </body>
</html>
