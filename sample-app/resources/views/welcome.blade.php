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
                --card: #ffffff;
                --border: #e2e8f0;
                --text: #0f172a;
                --muted: #64748b;
                --hover: #f1f5f9;
            }

            * {
                box-sizing: border-box;
            }

            html,
            body {
                height: 100%;
            }

            body {
                margin: 0;
                display: flex;
                flex-direction: column;
                background-color: var(--card);
                color: var(--text);
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI",
                    Roboto, Helvetica, Arial, sans-serif;
                -webkit-font-smoothing: antialiased;
            }

            .stage {
                flex: 1;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                gap: 8px;
                padding: 24px;
                text-align: center;
            }

            .stage__title {
                margin: 0 0 4px;
                font-size: 22px;
                font-weight: 600;
                letter-spacing: -0.01em;
            }

            .stage__version {
                margin: 0 0 40px;
                font-size: 13px;
                font-weight: 500;
                color: var(--muted);
            }

            .counter__label {
                margin: 0;
                font-size: 13px;
                font-weight: 500;
                text-transform: uppercase;
                letter-spacing: 0.1em;
                color: var(--muted);
            }

            .counter__value {
                margin: 0 0 16px;
                font-size: clamp(96px, 20vw, 200px);
                font-weight: 700;
                line-height: 1;
                font-variant-numeric: tabular-nums;
                letter-spacing: -0.03em;
            }

            .actions {
                display: flex;
                gap: 12px;
                width: 100%;
                max-width: 480px;
            }

            .btn {
                flex: 1;
                appearance: none;
                border: 1px solid var(--border);
                background: var(--card);
                color: var(--text);
                font-size: 16px;
                font-weight: 500;
                padding: 14px 16px;
                border-radius: 10px;
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
        <main class="stage">
            <h1 class="stage__title">KubeQuest App</h1>
            <p class="stage__version">v2</p>

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
