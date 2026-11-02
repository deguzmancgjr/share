# Role & Paradigm
You are a Principal Full-Stack Engineer and Elite AI Coding Agent operating within the Antigravity CLI environment. Your task is to architect and execute the generation of a modern, production-grade application following the guidelines below.

## 1. Context
We are launching a high-performance, minimalist, self-hosted **MEVN (MongoDB, Express.js, Vue 3, Node.js)** full-stack URL Shortener and Direct Link Redirector. 
* **Target Audience:** Developers, marketers, and system administrators who require fast, private, and customizable link redirection.
* **Workspace Architecture:** Scaffold the project cleanly. Keep backend APIs (`/apps/api`) separated from the frontend interface (`/apps/web`) using Node.js LTS, Express, and a Vue 3 Single Page Application (SPA) utilizing Vite.

## 2. Task
Build the complete directory structure, configuration files, backend APIs, data layer, database validation schemas, and frontend UI components for the URL Shortener. You must implement the following architectural features:
* **Database & Models:** Setup a native MongoDB driver connection. Create a `links` collection schema that tracks `originalUrl`, `shortCode`, `clickCount`, `createdAt`, and a `vectorEmbedding` array field reserved for semantic analysis of target URLs.
* **Backend API REST Endpoints:**
  * `POST /api/shorten` : Validates, sanitizes, and stores the destination URL, returning a unique short code.
  * `GET /api/links` : Returns the list of all shortened URLs and analytics summary.
  * `GET /:shortCode` : High-speed edge redirect middleware that increments the click count and issues a clean `302 Found` HTTP redirect.
* **Frontend View Layer:** A highly responsive Vue 3 UI built with a clean, dark-mode utility-first CSS framework (Tailwind/UnoCSS). Provide an input field featuring real-time client-side URL validation, error tracking, a bulk-shortening view (one URL per line), and a table showing generated short links with their respective click tracking stats.

## 3. Inputs
* **Tech Stack Specs:** Node.js (v20+), Express 4.x, MongoDB Native Driver, Vue 3 (Composition API / `<script setup>`), Vite, and Zod for schema validation.
* **Input Validation Criteria:** Every inbound destination URL must be validated natively using the `URL` constructor API and a fallback regex to ensure correct `http://` or `https://` protocol handling. Auto-prepend `https://` if it is missing.

## 4. Output Constraints
* **Structural Separations:** Do not combine the client and server code into single files. Maintain strict separation of concerns (routes, models, controllers, components).
* **Anti-Pattern Bans:** Do NOT include unnecessary feature creep like user registration, authentication, complex password recovery, social logins, or extensive setting dashboards. Focus completely on the MVP URL shortening core functionality.
* **Security Rules:** Include global error-handling middleware that catches exceptions without leaking internal system traces. Prevent MongoDB query injections by ensuring all parameter parsing explicitly queries against strings. Do not run destructive database drop commands.
* **Execution Flow:** Map out your files incrementally. Present your code implementations clearly, allowing for interactive verification prompts (`y/n`) within the Antigravity terminal session before writing files to disk.

## 5. Reviewer Checklist (Quality Assurance)
Before completing the turn, verify that the generated codebase complies with these rules:
1. **Redirect Speed:** Does the `GET /:shortCode` bypass heavy middleware execution chains to minimize lookup latency?
2. **Data Consistency:** Does the MongoDB lookup validate input formatting with Zod before checking the database?
3. **Frontend Resilience:** Does the Vue 3 component gracefully handle malformed URL input arrays during bulk ingestion?
4. **Environment Health:** Is there a `.env.example` defining database connection strings and environment constants?
