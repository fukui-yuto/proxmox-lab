// {{ cookiecutter.description }}
const os = require("os");

console.log("=".repeat(50));
console.log("Job: {{ cookiecutter.job_name }}");
console.log("{{ cookiecutter.description }}");
console.log("=".repeat(50));
console.log(`Node.js version: ${process.version}`);
console.log(`Platform: ${os.platform()} ${os.arch()}`);
console.log(`Timestamp: ${new Date().toISOString()}`);
console.log("=".repeat(50));
console.log("Build successful!");
