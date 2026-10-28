import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getAccessToken, getIdentity, hasRole, initializeAuth, login, logout } from "./auth";

const USER_API = "/user-api";
const TX_API = "/transaction-api";
const ACTIVITY_API = "/activity-api";
const FINANCE_AGENT_API = "/finance-agent-api";

const currency = new Intl.NumberFormat("en-GB", {
  style: "currency",
  currency: "GBP",
});

export default function TechbleatGlobalBankCustomerApp() {
  const [screen, setScreen] = useState("login");
  const [authReady, setAuthReady] = useState(false);
  const [authenticated, setAuthenticated] = useState(false);
  const [usersLoaded, setUsersLoaded] = useState(false);
  const [users, setUsers] = useState([]);
  const [selectedUserId, setSelectedUserId] = useState("");
  const [balance, setBalance] = useState(0);
  const [transactions, setTransactions] = useState([]);
  const [activities, setActivities] = useState([]);
  const [loading, setLoading] = useState(false);
  const [registering, setRegistering] = useState(false);
  const [message, setMessage] = useState({ type: "info", text: "" });
  const [assistantOpen, setAssistantOpen] = useState(false);
  const [assistantInput, setAssistantInput] = useState("");
  const [assistantMessages, setAssistantMessages] = useState([
    {
      role: "assistant",
      content: "Hello! I’m your banking assistant. Ask me about your balance or recent transactions.",
    },
  ]);
  const [assistantLoading, setAssistantLoading] = useState(false);

  const [registerForm, setRegisterForm] = useState({
    id: "",
    firstName: "",
    lastName: "",
    email: "",
    password: "",
    confirmPassword: "",
  });

  const [transferForm, setTransferForm] = useState({
    type: "deposit",
    amount: "",
    toUserId: "",
    reference: "",
  });

  const selectedUser = useMemo(
    () => users.find((user) => user.id === selectedUserId) || null,
    [users, selectedUserId],
  );
  const identity = authenticated ? getIdentity() : null;
  const canViewBanking = authenticated && hasRole(import.meta.env.VITE_BANKING_VIEW_ROLE || "banking-customer");
  const canTransact = canViewBanking && hasRole(import.meta.env.VITE_BANKING_TRANSACTION_ROLE || "banking-transact");
  const canUseAssistant = canViewBanking && hasRole(import.meta.env.VITE_BANKING_AI_AGENT_ROLE || "banking-ai-agent");

  const spendingThisMonth = useMemo(() => {
    const now = new Date();
    return transactions
      .filter((tx) => {
        const d = new Date(tx.createdAt);
        return d.getFullYear() === now.getFullYear()
            && d.getMonth() === now.getMonth()
            && (String(tx.transactionType || "").includes("WITHDRAW") || String(tx.transactionType || "").includes("OUT"));
      })
      .reduce((sum, tx) => sum + Math.abs(Number(tx.amount || 0)), 0);
  }, [transactions]);

  const moneyInThisMonth = useMemo(() => {
    const now = new Date();
    return transactions
      .filter((tx) => {
        const d = new Date(tx.createdAt);
        const type = String(tx.transactionType || "");
        return d.getFullYear() === now.getFullYear()
            && d.getMonth() === now.getMonth()
            && (type.includes("DEPOSIT") || type.includes("IN"));
      })
      .reduce((sum, tx) => sum + Number(tx.amount || 0), 0);
  }, [transactions]);

  const safeToSpend = Math.max(balance - 500, 0);
  const closeAssistant = useCallback(() => setAssistantOpen(false), []);

  useEffect(() => {
    initializeAuth()
      .then((isAuthenticated) => {
        setAuthenticated(isAuthenticated);
        setAuthReady(true);
      })
      .catch((error) => {
        setMessage({ type: "error", text: error.message || "Unable to connect to Keycloak" });
        setAuthReady(true);
      });
  }, []);

  useEffect(() => {
    if (authenticated && canViewBanking) void loadUsers();
  }, [authenticated, canViewBanking]);

  useEffect(() => {
    if (selectedUserId) {
      void loadDashboard(selectedUserId);
      setAssistantOpen(false);
      setAssistantMessages([
        {
          role: "assistant",
          content: "Hello! I’m your banking assistant. Ask me about your balance or recent transactions.",
        },
      ]);
    }
  }, [selectedUserId]);

  async function api(url, options = {}) {
    const accessToken = await getAccessToken();
    const response = await fetch(url, {
      ...options,
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken}`,
        ...(options.headers || {}),
      },
    });

    if (!response.ok) {
      let errorText = "Request failed";
      try {
        const data = await response.json();
        const d = data.detail ?? data.message;
        errorText = d == null
          ? JSON.stringify(data)
          : typeof d === "string" ? d
          : Array.isArray(d) ? d.map((e) => e.msg || JSON.stringify(e)).join("; ")
          : JSON.stringify(d);
      } catch {
        errorText = await response.text();
      }
      throw new Error(errorText || "Request failed");
    }

    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      return response.json();
    }
    return response.text();
  }

  async function sendAssistantMessage(event) {
    event.preventDefault();
    const prompt = assistantInput.trim();
    if (!prompt || assistantLoading) return;

    setAssistantInput("");
    setAssistantMessages((current) => [...current, { role: "user", content: prompt }]);
    setAssistantLoading(true);

    try {
      const accessToken = await getAccessToken();
      const response = await fetch(`${FINANCE_AGENT_API}/chat`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${accessToken}`,
        },
        body: JSON.stringify({ message: prompt }),
      });

      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new Error(data.detail || data.message || "The assistant could not answer. Please try again.");
      }
      if (typeof data.answer !== "string" || !data.answer.trim()) {
        throw new Error("The assistant returned an empty response. Please try again.");
      }

      setAssistantMessages((current) => [...current, { role: "assistant", content: data.answer }]);
    } catch (error) {
      setAssistantMessages((current) => [
        ...current,
        { role: "error", content: error.message || "Unable to reach the assistant. Please try again." },
      ]);
    } finally {
      setAssistantLoading(false);
    }
  }

  async function loadUsers() {
    try {
      const data = await api(`${USER_API}/users`);
      const bankUsers = Array.isArray(data) ? data : [];
      setUsers(bankUsers);
      const userName = identity?.preferred_username;
      const email = identity?.email?.toLowerCase();
      const account = bankUsers.find(
        (user) => user.id === userName || user.email?.toLowerCase() === email,
      );
      if (account) {
        setSelectedUserId(account.id);
        setScreen("dashboard");
        setMessage({ type: "success", text: `Signed in as ${account.full_name}` });
      } else {
        setMessage({
          type: "error",
          text: "No bank profile matches your Keycloak username or email. Ask an administrator to link your account.",
        });
      }
    } catch (error) {
      setMessage({ type: "error", text: error.message || "Unable to load users" });
    } finally {
      setUsersLoaded(true);
    }
  }

  async function loadDashboard(userId) {
    setLoading(true);
    try {
      const [balanceRes, transactionsRes, activitiesRes] = await Promise.all([
        api(`${TX_API}/balance/${userId}`),
        api(`${TX_API}/transactions/${userId}`),
        api(`${ACTIVITY_API}/activities/${userId}`),
      ]);
      setBalance(Number(balanceRes.balance || 0));
      setTransactions(Array.isArray(transactionsRes) ? transactionsRes : []);
      setActivities(Array.isArray(activitiesRes) ? activitiesRes : []);
      setMessage({ type: "success", text: `Loaded dashboard for ${userId}` });
    } catch (error) {
      setMessage({ type: "error", text: error.message || "Unable to load dashboard" });
    } finally {
      setLoading(false);
    }
  }

  async function handleTransfer(event) {
    event.preventDefault();
    if (!selectedUserId) {
      setMessage({ type: "error", text: "Please sign in first." });
      return;
    }

    const amount = Number(transferForm.amount);
    if (!amount || amount <= 0) {
      setMessage({ type: "error", text: "Enter a valid amount." });
      return;
    }

    try {
      if (transferForm.type === "deposit") {
        await api(`${TX_API}/transactions/deposit`, {
          method: "POST",
          headers: { "X-User-Id": selectedUserId, "Content-Type": "application/json" },
          body: JSON.stringify({ amount }),
        });
      } else if (transferForm.type === "withdraw") {
        await api(`${TX_API}/transactions/withdraw`, {
          method: "POST",
          headers: { "X-User-Id": selectedUserId, "Content-Type": "application/json" },
          body: JSON.stringify({ amount }),
        });
      } else {
        if (!transferForm.toUserId.trim()) {
          setMessage({ type: "error", text: "Enter a destination user ID." });
          return;
        }
        await api(`${TX_API}/transactions/transfer`, {
          method: "POST",
          headers: { "X-User-Id": selectedUserId, "Content-Type": "application/json" },
          body: JSON.stringify({
            toUserId: transferForm.toUserId.trim(),
            amount,
            ...(transferForm.reference.trim() ? { reference: transferForm.reference.trim() } : {}),
          }),
        });
      }

      setTransferForm({ type: "deposit", amount: "", toUserId: "", reference: "" });
      await loadDashboard(selectedUserId);
      setScreen("dashboard");
      setMessage({ type: "success", text: "Transaction completed successfully." });
    } catch (error) {
      setMessage({ type: "error", text: error.message || "Transaction failed" });
    }
  }

  async function handleRegister(event) {
    event.preventDefault();
    if (registerForm.password !== registerForm.confirmPassword) {
      setMessage({ type: "error", text: "Passwords do not match." });
      return;
    }

    setRegistering(true);

    const profile = {
      id: registerForm.id.trim(),
      full_name: `${registerForm.firstName.trim()} ${registerForm.lastName.trim()}`,
      email: registerForm.email.trim(),
      password: registerForm.password,
    };

    try {
      const response = await fetch(`${USER_API}/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(profile),
      });

      if (!response.ok) {
        const body = await response.text();
        let errorText = body || "Unable to create your bank profile.";
        try {
          const data = JSON.parse(body);
          const d = data.detail ?? data.message;
          if (d != null) {
            errorText = typeof d === "string" ? d
              : Array.isArray(d) ? d.map((e) => e.msg || JSON.stringify(e)).join("; ")
              : JSON.stringify(d);
          }
        } catch {
          // Keep the response text when the service does not return JSON.
        }
        throw new Error(errorText);
      }

      setRegisterForm({ id: "", firstName: "", lastName: "", email: "", password: "", confirmPassword: "" });
      setMessage({
        type: "success",
        text: "Account created. An administrator must grant banking-customer before you can access banking.",
      });
      setScreen("login");
    } catch (error) {
      setMessage({ type: "error", text: error.message || "Unable to start registration." });
    } finally {
      setRegistering(false);
    }
  }

  function handleLogout() {
    setAssistantOpen(false);
    setAssistantMessages([
      {
        role: "assistant",
        content: "Hello! I’m your banking assistant. Ask me about your balance or recent transactions.",
      },
    ]);
    void logout();
  }

  const accounts = [
    {
      name: "Everyday Account",
      number: selectedUser ? `•••• ${selectedUser.id.slice(-4).padStart(4, "0")}` : "•••• 2048",
      balance: currency.format(balance),
    },
    {
      name: "Savings Account",
      number: "•••• 8831",
      balance: currency.format(Math.max(balance * 0.6, 0)),
    },
  ];

  const quickActions = [
    ...(canTransact ? [
      { label: "Deposit Funds", screen: "transfer", mode: "deposit" },
      { label: "Withdraw Funds", screen: "transfer", mode: "withdraw" },
      { label: "Transfer Money", screen: "transfer", mode: "transfer" },
    ] : []),
    { label: "View Reports", screen: "report" },
  ];

  return (
    <div className="min-h-screen bg-slate-950 text-white">
      <div className="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8">
        <TopNav
          screen={screen}
          setScreen={setScreen}
          selectedUser={selectedUser}
          identityName={identity?.preferred_username || identity?.email}
          canTransact={canTransact}
          canUseAssistant={canUseAssistant}
          onOpenAssistant={() => setAssistantOpen(true)}
          onLogout={handleLogout}
        />

        {message.text ? <Banner message={message} /> : null}

        {!authReady ? <p className="py-16 text-center text-slate-300">Connecting to Keycloak…</p> : null}

        {authReady && !authenticated && screen === "login" && (
          <LoginScreen onLogin={() => void login()} onRegister={() => setScreen("register")} />
        )}

        {authReady && !authenticated && screen === "register" && (
          <RegisterScreen
            registerForm={registerForm}
            setRegisterForm={setRegisterForm}
            onRegister={handleRegister}
            onGoLogin={() => {
              setMessage({ type: "info", text: "" });
              setScreen("login");
            }}
            registering={registering}
          />
        )}

        {authenticated && !canViewBanking && (
          <AccessDenied
            type="approval"
            identityName={identity?.preferred_username || identity?.email}
            role={import.meta.env.VITE_BANKING_VIEW_ROLE || "banking-customer"}
            onLogout={handleLogout}
          />
        )}

        {authenticated && canViewBanking && !usersLoaded && (
          <p className="py-16 text-center text-slate-300">Loading your bank profile…</p>
        )}

        {authenticated && canViewBanking && usersLoaded && !selectedUser && (
          <AccessDenied
            type="profile"
            identityName={identity?.preferred_username || identity?.email}
            onLogout={handleLogout}
          />
        )}

        {canViewBanking && selectedUser && screen === "dashboard" && (
          <DashboardScreen
            selectedUser={selectedUser}
            accounts={accounts}
            balance={balance}
            quickActions={quickActions}
            onQuickAction={(action) => {
              if (action.mode) {
                setTransferForm((prev) => ({ ...prev, type: action.mode }));
              }
              setScreen(action.screen);
            }}
            transactions={transactions}
            spendingThisMonth={spendingThisMonth}
            moneyInThisMonth={moneyInThisMonth}
            safeToSpend={safeToSpend}
            loading={loading}
            canTransact={canTransact}
          />
        )}

        {canTransact && selectedUser && screen === "transfer" && (
          <TransferScreen
            selectedUser={selectedUser}
            transferForm={transferForm}
            setTransferForm={setTransferForm}
            onSubmit={handleTransfer}
            users={users}
            balance={balance}
          />
        )}

        {canViewBanking && selectedUser && screen === "report" && (
          <ReportScreen
            selectedUser={selectedUser}
            balance={balance}
            transactions={transactions}
            activities={activities}
            moneyInThisMonth={moneyInThisMonth}
            spendingThisMonth={spendingThisMonth}
            safeToSpend={safeToSpend}
          />
        )}

        {canUseAssistant && selectedUser && assistantOpen && (
          <AssistantChat
            messages={assistantMessages}
            input={assistantInput}
            setInput={setAssistantInput}
            loading={assistantLoading}
            onSubmit={sendAssistantMessage}
            onClose={closeAssistant}
          />
        )}
      </div>
    </div>
  );
}

function TopNav({ screen, setScreen, selectedUser, identityName, canTransact, canUseAssistant, onOpenAssistant, onLogout }) {
  const nav = selectedUser
    ? ["dashboard", ...(canTransact ? ["transfer"] : []), "report"]
    : [];

  return (
    <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
      <div className="flex flex-wrap gap-3">
        {nav.map((item) => (
          <button
            key={item}
            type="button"
            onClick={() => setScreen(item)}
            className={`rounded-2xl px-4 py-2 text-sm capitalize transition ${
              item === screen
                ? "bg-gradient-to-r from-cyan-400 to-blue-600 text-slate-950"
                : "border border-white/10 bg-white/5 text-slate-300 hover:bg-white/10"
            }`}
          >
            {item}
          </button>
        ))}
      </div>

      <div className="flex items-center gap-3">
        {selectedUser && canUseAssistant ? (
          <button
            type="button"
            onClick={onOpenAssistant}
            className="rounded-2xl bg-gradient-to-r from-cyan-400 to-blue-500 px-4 py-2 text-sm font-semibold text-slate-950 shadow-lg shadow-cyan-950/25 transition hover:from-cyan-300 hover:to-blue-400 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-cyan-300"
          >
            AI Assistant
          </button>
        ) : null}
        {identityName ? (
          <div className="rounded-2xl border border-white/10 bg-white/5 px-4 py-2 text-sm text-slate-300">
            Signed in as <span className="font-semibold text-white">{selectedUser?.full_name || identityName}</span>
          </div>
        ) : null}
        {identityName ? (
          <button
            type="button"
            onClick={onLogout}
            className="rounded-2xl border border-white/10 bg-white/5 px-4 py-2 text-sm text-slate-300 hover:bg-white/10"
          >
            Logout
          </button>
        ) : null}
      </div>
    </div>
  );
}

function AssistantChat({ messages, input, setInput, loading, onSubmit, onClose }) {
  const messageListRef = useRef(null);
  const inputRef = useRef(null);

  useEffect(() => {
    messageListRef.current?.scrollTo({ top: messageListRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, loading]);

  useEffect(() => {
    inputRef.current?.focus();
    function closeOnEscape(event) {
      if (event.key === "Escape") onClose();
    }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-slate-950/70 p-0 backdrop-blur-sm sm:items-center sm:p-5" onMouseDown={(event) => {
      if (event.target === event.currentTarget) onClose();
    }}>
      <section
        aria-labelledby="assistant-title"
        aria-modal="true"
        className="flex h-[min(720px,92vh)] w-full max-w-xl flex-col overflow-hidden rounded-t-[28px] border border-white/10 bg-slate-900 shadow-2xl shadow-black/50 sm:rounded-[28px]"
        role="dialog"
      >
        <header className="flex items-center justify-between border-b border-white/10 bg-gradient-to-r from-slate-900 via-slate-900 to-cyan-950/60 px-5 py-4">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-cyan-300/10 text-lg text-cyan-200" aria-hidden="true">✦</div>
            <div>
              <h2 id="assistant-title" className="font-semibold text-white">Banking AI Assistant</h2>
              <p className="text-xs text-slate-400">Private to your signed-in account</p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close AI Assistant"
            className="flex h-9 w-9 items-center justify-center rounded-xl border border-white/10 text-slate-300 transition hover:bg-white/10 hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-cyan-300"
          >
            ×
          </button>
        </header>

        <div ref={messageListRef} className="flex-1 space-y-4 overflow-y-auto px-4 py-5 sm:px-5" aria-live="polite">
          {messages.map((message, index) => (
            <div key={`${message.role}-${index}`} className={`flex ${message.role === "user" ? "justify-end" : "justify-start"}`}>
              <div className={`max-w-[88%] rounded-2xl px-4 py-3 text-sm leading-6 ${
                message.role === "user"
                  ? "rounded-br-md bg-cyan-400 text-slate-950"
                  : message.role === "error"
                    ? "rounded-bl-md border border-rose-400/20 bg-rose-500/10 text-rose-200"
                    : "rounded-bl-md border border-white/10 bg-slate-800 text-slate-100"
              }`}>
                {message.role === "assistant"
                  ? <FormattedAssistantAnswer content={message.content} />
                  : <p className="whitespace-pre-wrap">{message.content}</p>}
              </div>
            </div>
          ))}
          {loading ? (
            <div className="flex justify-start" role="status" aria-label="Assistant is responding">
              <div className="rounded-2xl rounded-bl-md border border-white/10 bg-slate-800 px-4 py-3 text-sm text-slate-400">
                Checking your banking information…
              </div>
            </div>
          ) : null}
        </div>

        <form onSubmit={onSubmit} className="border-t border-white/10 bg-slate-950/70 p-4 sm:p-5">
          <label className="sr-only" htmlFor="assistant-message">Message the banking assistant</label>
          <div className="flex items-end gap-2 rounded-2xl border border-white/10 bg-slate-900 p-2 focus-within:border-cyan-300/50">
            <textarea
              ref={inputRef}
              id="assistant-message"
              value={input}
              onChange={(event) => setInput(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !event.shiftKey) {
                  event.preventDefault();
                  event.currentTarget.form?.requestSubmit();
                }
              }}
              maxLength={2000}
              rows={1}
              placeholder="Ask about your balance or transactions…"
              className="max-h-28 min-h-11 flex-1 resize-y bg-transparent px-3 py-2 text-sm text-white outline-none placeholder:text-slate-500"
              disabled={loading}
            />
            <button
              type="submit"
              disabled={loading || !input.trim()}
              className="min-h-11 rounded-xl bg-gradient-to-r from-cyan-400 to-blue-500 px-4 text-sm font-semibold text-slate-950 transition hover:from-cyan-300 hover:to-blue-400 disabled:cursor-not-allowed disabled:opacity-40"
            >
              Send
            </button>
          </div>
          <p className="mt-2 px-1 text-xs text-slate-500">For information only. The assistant cannot make payments or transfers.</p>
        </form>
      </section>
    </div>
  );
}

function FormattedAssistantAnswer({ content }) {
  const lines = content.split(/\r?\n/);
  const blocks = [];
  let bullets = [];
  let paragraph = [];

  function flushParagraph() {
    if (!paragraph.length) return;
    blocks.push(<p key={`p-${blocks.length}`} className="mb-2 last:mb-0">{formatInline(paragraph.join(" "))}</p>);
    paragraph = [];
  }

  function flushBullets() {
    if (!bullets.length) return;
    blocks.push(
      <ul key={`ul-${blocks.length}`} className="mb-2 list-disc space-y-1 pl-5 last:mb-0">
        {bullets.map((item, index) => <li key={index}>{formatInline(item)}</li>)}
      </ul>,
    );
    bullets = [];
  }

  lines.forEach((rawLine) => {
    const line = rawLine.trim();
    if (!line) {
      flushParagraph();
      flushBullets();
      return;
    }
    const bullet = line.match(/^(?:[-*•]|\d+[.)])\s+(.+)$/);
    if (bullet) {
      flushParagraph();
      bullets.push(bullet[1]);
      return;
    }
    flushBullets();
    const heading = line.match(/^#{1,3}\s+(.+)$/);
    if (heading) {
      flushParagraph();
      blocks.push(<h3 key={`h-${blocks.length}`} className="mb-2 font-semibold text-cyan-200">{formatInline(heading[1])}</h3>);
      return;
    }
    paragraph.push(line);
  });
  flushParagraph();
  flushBullets();

  return <div>{blocks}</div>;
}

function formatInline(text) {
  return text.split(/(\*\*[^*]+\*\*)/g).map((part, index) => {
    if (part.startsWith("**") && part.endsWith("**")) {
      return <strong key={index} className="font-semibold text-white">{part.slice(2, -2)}</strong>;
    }
    return part;
  });
}

function Banner({ message }) {
  const tones = {
    success: "border-emerald-400/20 bg-emerald-500/10 text-emerald-200",
    error: "border-rose-400/20 bg-rose-500/10 text-rose-200",
    info: "border-cyan-400/20 bg-cyan-500/10 text-cyan-200",
  };

  return (
    <div className={`mb-6 rounded-2xl border px-4 py-3 text-sm ${tones[message.type] || tones.info}`}>
      {message.text}
    </div>
  );
}

function AccessDenied({ type, identityName, role, onLogout }) {
  const needsApproval = type === "approval";

  return (
    <section className="mx-auto max-w-3xl py-8 sm:py-14">
      <div className="overflow-hidden rounded-2xl border border-white/10 bg-slate-900/80 shadow-2xl shadow-black/20">
        <div className="border-b border-white/10 bg-gradient-to-r from-cyan-950/70 via-slate-900 to-slate-900 px-6 py-8 sm:px-10 sm:py-10">
          <div className="mb-6 flex h-12 w-12 items-center justify-center rounded-full border border-cyan-300/30 bg-cyan-300/10 text-xl text-cyan-200" aria-hidden="true">
            {needsApproval ? "…" : "i"}
          </div>
          <p className="text-sm font-medium uppercase tracking-[0.18em] text-cyan-300">
            {needsApproval ? "Access pending" : "Profile setup"}
          </p>
          <h1 className="mt-3 max-w-xl text-3xl font-semibold leading-tight text-white sm:text-4xl">
            {needsApproval ? "You’re signed in. Banking access is pending." : "Your bank profile isn’t linked yet."}
          </h1>
          <p className="mt-4 max-w-2xl text-base leading-7 text-slate-300">
            {needsApproval
              ? "Your sign-in is working. An administrator still needs to enable your banking access."
              : "Your sign-in is working, but we couldn’t match it to a bank profile."}
          </p>
        </div>

        <div className="grid gap-8 px-6 py-7 sm:grid-cols-[1fr_auto] sm:items-end sm:px-10 sm:py-8">
          <div>
            <p className="text-xs font-medium uppercase tracking-[0.16em] text-slate-500">Next step</p>
            <p className="mt-2 max-w-xl text-sm leading-6 text-slate-200">
              {needsApproval
                ? <>Ask your bank administrator to assign the <span className="font-semibold text-white">{role}</span> role to your Keycloak account. After approval, sign out and sign in again.</>
                : "Ask your bank administrator to link your bank profile to this Keycloak username or email address."}
            </p>
            {identityName ? (
              <p className="mt-5 text-sm text-slate-400">
                Signed in as <span className="font-medium text-slate-200">{identityName}</span>
              </p>
            ) : null}
          </div>
          <button
            type="button"
            onClick={onLogout}
            className="rounded-lg border border-white/15 px-5 py-3 text-sm font-medium text-white transition hover:border-white/30 hover:bg-white/5"
          >
            Sign out
          </button>
        </div>
      </div>
    </section>
  );
}

function Shell({ children, title, subtitle, aside }) {
  return (
    <div className="grid gap-6 xl:grid-cols-[1.05fr_0.95fr]">
      <div className="rounded-[32px] border border-white/10 bg-slate-900/85 p-8 shadow-2xl shadow-black/30">
        <p className="text-sm uppercase tracking-[0.25em] text-cyan-300">Techbleat Global Bank</p>
        <h1 className="mt-3 text-4xl font-semibold">{title}</h1>
        <p className="mt-3 max-w-xl text-sm leading-6 text-slate-400">{subtitle}</p>
        <div className="mt-8">{children}</div>
      </div>
      <div className="rounded-[32px] border border-white/10 bg-gradient-to-br from-slate-900 via-blue-950/60 to-cyan-950/40 p-8 shadow-2xl shadow-black/30">
        {aside}
      </div>
    </div>
  );
}

function LoginScreen({ onLogin, onRegister }) {
  return (
    <main className="mx-auto grid min-h-[min(720px,calc(100vh-8rem))] max-w-6xl overflow-hidden rounded-[28px] border border-white/10 bg-slate-950 shadow-2xl shadow-black/30 lg:grid-cols-[1.08fr_0.92fr]">
      <section
        className="relative flex min-h-72 flex-col justify-between overflow-hidden p-7 sm:p-10 lg:min-h-[620px] lg:p-14"
        style={{ backgroundImage: "radial-gradient(circle at 78% 23%, rgba(34, 211, 238, 0.18), transparent 30%), linear-gradient(145deg, #0f172a 0%, #0b1725 56%, #082f49 100%)" }}
      >
        <div className="relative z-10 flex items-center gap-3">
          <div className="flex h-11 w-11 items-center justify-center rounded-xl border border-cyan-200/30 bg-cyan-300/10 text-xl font-semibold text-cyan-200">T</div>
          <div>
            <p className="text-sm font-semibold tracking-wide text-white">TECHBLEAT</p>
            <p className="text-xs text-slate-400">GLOBAL BANK</p>
          </div>
        </div>

        <div className="relative z-10 mt-14 max-w-xl lg:mt-0">
          <p className="text-xs font-medium uppercase tracking-[0.2em] text-cyan-300">Personal banking</p>
          <h1 className="mt-5 text-4xl font-semibold leading-tight text-white sm:text-5xl">Good to see you again.</h1>
          <p className="mt-5 max-w-md text-base leading-7 text-slate-300">
            Your financial life, ready when you are.
          </p>
        </div>

        <div className="relative z-10 mt-12 flex items-center gap-3 border-t border-white/10 pt-5 text-xs text-slate-400 lg:mt-0">
          <span className="h-2 w-2 rounded-full bg-emerald-400" />
          <span>Private online banking</span>
        </div>

        <div aria-hidden="true" className="pointer-events-none absolute -bottom-32 -right-28 h-80 w-80 rounded-full border border-cyan-200/10 shadow-[0_0_0_36px_rgba(34,211,238,0.025),0_0_0_72px_rgba(34,211,238,0.02)]" />
      </section>

      <section className="flex flex-col justify-center border-t border-white/10 bg-slate-900/70 px-7 py-10 sm:px-12 lg:border-l lg:border-t-0 lg:px-14">
        <p className="text-xs font-medium uppercase tracking-[0.18em] text-slate-500">Your account</p>
        <h2 className="mt-3 text-2xl font-semibold text-white">Sign in</h2>
        <p className="mt-3 text-sm leading-6 text-slate-400">Continue to your personal banking.</p>

        <button
          type="button"
          onClick={onLogin}
          className="mt-8 flex min-h-14 w-full items-center justify-center rounded-xl bg-gradient-to-r from-cyan-300 to-cyan-400 px-5 py-4 text-base font-semibold text-slate-950 shadow-lg shadow-cyan-950/30 transition hover:from-cyan-200 hover:to-cyan-300 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-cyan-300"
        >
          Sign in
        </button>

        <p className="mt-7 text-center text-sm text-slate-400">
          New to Techbleat?{" "}
          <button type="button" onClick={onRegister} className="font-medium text-cyan-300 underline-offset-4 hover:underline">
            Create an account
          </button>
        </p>

        <p className="mt-12 border-t border-white/10 pt-5 text-xs leading-5 text-slate-500">
          Your account is protected with secure sign-in.
        </p>
      </section>
    </main>
  );
}

function RegisterScreen({ registerForm, setRegisterForm, onRegister, onGoLogin, registering }) {
  return (
    <Shell
      title="Create your account"
      subtitle="Create your bank and sign-in details in one step."
      aside={
        <div className="flex h-full flex-col justify-between">
          <div className="rounded-[30px] border border-white/10 bg-white/5 p-6">
            <p className="text-sm text-cyan-300">Account setup</p>
            <h3 className="mt-3 text-2xl font-semibold">Two linked profiles</h3>
            <p className="mt-3 text-sm leading-7 text-slate-300">
              An administrator will grant banking access after your account is created.
            </p>
          </div>
        </div>
      }
    >
      <form onSubmit={onRegister}>
        <div className="grid gap-5 md:grid-cols-2">
          <FormField
            label="User ID"
            placeholder="segun"
            value={registerForm.id}
            onChange={(value) => setRegisterForm((prev) => ({ ...prev, id: value }))}
            required
          />
          <div />
          <FormField
            label="First name"
            placeholder="Alice"
            value={registerForm.firstName}
            onChange={(value) => setRegisterForm((prev) => ({ ...prev, firstName: value }))}
            required
          />
          <FormField
            label="Last name"
            placeholder="Johnson"
            value={registerForm.lastName}
            onChange={(value) => setRegisterForm((prev) => ({ ...prev, lastName: value }))}
            required
          />
          <FormField
            label="Email"
            placeholder="alice@example.com"
            type="email"
            value={registerForm.email}
            onChange={(value) => setRegisterForm((prev) => ({ ...prev, email: value }))}
            required
          />
          <FormField
            label="Password"
            placeholder="At least 3 characters"
            type="password"
            value={registerForm.password}
            onChange={(value) => setRegisterForm((prev) => ({ ...prev, password: value }))}
            minLength={3}
            required
          />
          <FormField
            label="Confirm password"
            placeholder="Re-enter your password"
            type="password"
            value={registerForm.confirmPassword}
            onChange={(value) => setRegisterForm((prev) => ({ ...prev, confirmPassword: value }))}
            minLength={3}
            required
          />
        </div>
        <button type="submit" disabled={registering} className="mt-6 w-full rounded-2xl bg-gradient-to-r from-cyan-400 to-blue-600 px-5 py-4 font-medium text-slate-950 shadow-lg shadow-cyan-500/25 disabled:cursor-wait disabled:opacity-60">
          {registering ? "Creating account…" : "Create account"}
        </button>
        <p className="mt-4 text-center text-sm text-slate-400">
          <button type="button" onClick={onGoLogin} className="text-cyan-300">
            Back to sign in
          </button>
        </p>
      </form>
    </Shell>
  );
}

function DashboardScreen({
  selectedUser,
  accounts,
  balance,
  quickActions,
  onQuickAction,
  transactions,
  spendingThisMonth,
  moneyInThisMonth,
  safeToSpend,
  loading,
  canTransact,
}) {
  return (
    <>
      <header className="mb-8 flex flex-col gap-4 rounded-[32px] border border-white/10 bg-gradient-to-r from-slate-900 to-slate-800 px-6 py-6 shadow-2xl shadow-black/30 md:flex-row md:items-center md:justify-between">
        <div className="flex items-center gap-4">
          <div className="flex h-14 w-14 items-center justify-center rounded-3xl bg-gradient-to-br from-cyan-400 to-blue-600 text-xl font-bold text-slate-950 shadow-lg shadow-cyan-500/20">
            T
          </div>
          <div>
            <p className="text-sm uppercase tracking-[0.25em] text-cyan-300">Mobile & Web Banking</p>
            <h1 className="mt-1 text-3xl font-semibold">Techbleat Global Bank</h1>
            <p className="mt-2 text-sm text-slate-400">
              {selectedUser ? `Welcome back, ${selectedUser.full_name}` : "Please sign in to view your dashboard."}
            </p>
          </div>
        </div>

        <div className="flex items-center gap-3">
          <div className="rounded-2xl border border-white/10 bg-white/5 px-4 py-3 text-sm text-slate-300">
            Current balance <span className="font-medium text-white">{currency.format(balance)}</span>
          </div>
          {canTransact ? <button
            className="rounded-2xl bg-gradient-to-r from-cyan-400 to-blue-600 px-5 py-3 text-sm font-medium text-slate-950 shadow-lg shadow-cyan-500/25"
            onClick={() => onQuickAction({ screen: "transfer", mode: "transfer" })}
          >
            Send Money
          </button> : null}
        </div>
      </header>

      <section className="mb-8 rounded-[32px] border border-white/10 bg-gradient-to-br from-cyan-500/15 via-slate-900 to-blue-600/10 p-7 shadow-2xl shadow-black/20">
        <p className="text-sm text-cyan-200">Available Balance</p>
        <h2 className="mt-3 text-5xl font-semibold tracking-tight">{currency.format(balance)}</h2>
        <p className="mt-3 text-sm text-slate-300">Across your personal accounts</p>

        <div className="mt-8 grid gap-4 md:grid-cols-2">
          {accounts.map((account) => (
            <div key={account.name} className="rounded-[28px] border border-white/10 bg-white/5 p-5 backdrop-blur">
              <p className="text-sm text-slate-400">{account.name}</p>
              <p className="mt-1 text-sm text-slate-500">{account.number}</p>
              <h3 className="mt-4 text-2xl font-semibold">{account.balance}</h3>
            </div>
          ))}
        </div>
      </section>

      <section className="mb-8 grid gap-6 xl:grid-cols-[0.95fr_1.05fr]">
        <div className="rounded-[32px] border border-white/10 bg-slate-900/80 p-6 shadow-2xl shadow-black/20">
          <div className="mb-5 flex items-center justify-between">
            <h3 className="text-xl font-semibold">Quick Actions</h3>
            <span className="text-sm text-slate-400">Everyday banking</span>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            {quickActions.map((action) => (
              <button
                key={action.label}
                onClick={() => onQuickAction(action)}
                className="rounded-2xl border border-white/10 bg-white/5 px-4 py-5 text-left text-sm font-medium text-slate-100 transition hover:bg-white/10"
              >
                {action.label}
              </button>
            ))}
          </div>

          <div className="mt-6 rounded-[28px] border border-emerald-400/20 bg-emerald-500/10 p-5">
            <p className="text-sm text-emerald-300">Savings Goal</p>
            <h4 className="mt-2 text-2xl font-semibold">Emergency Fund</h4>
            <p className="mt-2 text-sm text-slate-300">{currency.format(Math.min(balance, 5000))} of {currency.format(5000)} saved</p>
            <div className="mt-4 h-3 overflow-hidden rounded-full bg-white/10">
              <div className="h-full rounded-full bg-gradient-to-r from-emerald-400 to-cyan-400" style={{ width: `${Math.min((balance / 5000) * 100, 100)}%` }} />
            </div>
          </div>
        </div>

        <div className="rounded-[32px] border border-white/10 bg-slate-900/80 p-6 shadow-2xl shadow-black/20">
          <div className="mb-5 flex items-center justify-between">
            <h3 className="text-xl font-semibold">Cards</h3>
            <button className="rounded-xl border border-white/10 px-3 py-2 text-sm text-slate-300 hover:bg-white/5">
              Manage Cards
            </button>
          </div>

          <div className="rounded-[30px] bg-gradient-to-br from-slate-800 via-blue-950 to-cyan-900 p-6 shadow-xl shadow-cyan-900/20">
            <div className="flex items-start justify-between">
              <div>
                <p className="text-xs uppercase tracking-[0.25em] text-cyan-200">Platinum Debit</p>
                <p className="mt-8 text-2xl tracking-[0.3em] text-white">**** **** **** {selectedUser ? selectedUser.id.slice(-4).padStart(4, "0") : "2048"}</p>
              </div>
              <div className="rounded-full bg-white/10 px-3 py-1 text-xs text-slate-200">Active</div>
            </div>
            <div className="mt-10 flex items-end justify-between">
              <div>
                <p className="text-xs text-slate-300">Card Holder</p>
                <p className="mt-1 font-medium">{selectedUser?.full_name || "Customer"}</p>
              </div>
              <div>
                <p className="text-xs text-slate-300">Valid Thru</p>
                <p className="mt-1 font-medium">09/29</p>
              </div>
            </div>
          </div>

          <div className="mt-5 grid grid-cols-2 gap-4">
            <MetricCard title="Money In" value={currency.format(moneyInThisMonth)} tone="text-emerald-300" />
            <MetricCard title="Spent This Month" value={currency.format(spendingThisMonth)} tone="text-white" />
          </div>
        </div>
      </section>

      <section className="grid gap-6 xl:grid-cols-[1.2fr_0.8fr]">
        <div className="rounded-[32px] border border-white/10 bg-slate-900/80 p-6 shadow-2xl shadow-black/20">
          <div className="mb-5 flex items-center justify-between">
            <h3 className="text-xl font-semibold">Recent Transactions</h3>
            <button className="rounded-xl border border-white/10 px-3 py-2 text-sm text-slate-300 hover:bg-white/5">
              View Statement
            </button>
          </div>

          {loading ? <p className="text-sm text-slate-400">Loading transactions…</p> : null}

          <div className="space-y-4">
            {transactions.length === 0 ? (
              <div className="rounded-2xl border border-white/10 bg-white/5 px-4 py-4 text-sm text-slate-400">
                No transactions yet.
              </div>
            ) : (
              transactions.slice(0, 6).map((tx) => {
                const type = String(tx.transactionType || "");
                const isCredit = type.includes("DEPOSIT") || type.includes("IN");
                return (
                  <div key={`${tx.id}-${type}`} className="flex items-center justify-between rounded-2xl border border-white/10 bg-white/5 px-4 py-4">
                    <div>
                      <p className="font-medium">{niceType(type)}</p>
                      <p className="mt-1 text-sm text-slate-400">{tx.reference || "Techbleat Global Bank"}</p>
                    </div>
                    <div className="text-right">
                      <p className={`font-semibold ${isCredit ? "text-emerald-300" : "text-white"}`}>
                        {isCredit ? "+" : "-"}{currency.format(Math.abs(Number(tx.amount || 0))).replace("£", "£")}
                      </p>
                      <p className="mt-1 text-sm text-slate-400">{formatDate(tx.createdAt)}</p>
                    </div>
                  </div>
                );
              })
            )}
          </div>
        </div>

        <div className="rounded-[32px] border border-white/10 bg-slate-900/80 p-6 shadow-2xl shadow-black/20">
          <div className="mb-5 flex items-center justify-between">
            <h3 className="text-xl font-semibold">Insights</h3>
            <span className="text-sm text-slate-400">Personal overview</span>
          </div>

          <div className="space-y-4">
            <MetricCard title="Income This Month" value={currency.format(moneyInThisMonth)} tone="text-emerald-300" />
            <MetricCard title="Bills & Transfers" value={currency.format(spendingThisMonth)} tone="text-white" />
            <MetricCard title="Safe to Spend" value={currency.format(safeToSpend)} tone="text-white" />
          </div>
        </div>
      </section>
    </>
  );
}

function TransferScreen({ selectedUser, transferForm, setTransferForm, onSubmit, users, balance }) {
  const transferModes = [
    { id: "deposit", label: "Deposit" },
    { id: "withdraw", label: "Withdraw" },
    { id: "transfer", label: "Transfer" },
  ];

  return (
    <Shell
      title="Move money"
      subtitle="Use the real transaction APIs to deposit, withdraw or transfer funds."
      aside={
        <div className="space-y-5">
          <div className="rounded-[28px] border border-white/10 bg-white/5 p-6">
            <p className="text-sm text-slate-400">From</p>
            <h3 className="mt-2 text-2xl font-semibold">{selectedUser?.full_name || "No user selected"}</h3>
            <p className="mt-2 text-sm text-slate-300">Available: {currency.format(balance)}</p>
          </div>
          <div className="rounded-[28px] border border-emerald-400/20 bg-emerald-500/10 p-6">
            <p className="text-sm text-emerald-300">Transaction Summary</p>
            <div className="mt-4 space-y-3 text-sm text-slate-200">
              <div className="flex justify-between"><span>Mode</span><span>{niceType(transferForm.type)}</span></div>
              <div className="flex justify-between"><span>Amount</span><span>{currency.format(Number(transferForm.amount || 0))}</span></div>
              <div className="flex justify-between"><span>Fee</span><span>{currency.format(0)}</span></div>
              <div className="flex justify-between border-t border-white/10 pt-3 font-medium"><span>Total</span><span>{currency.format(Number(transferForm.amount || 0))}</span></div>
            </div>
          </div>
        </div>
      }
    >
      <form className="space-y-5" onSubmit={onSubmit}>
        <div className="grid gap-3 sm:grid-cols-3">
          {transferModes.map((mode) => (
            <button
              key={mode.id}
              type="button"
              onClick={() => setTransferForm((prev) => ({ ...prev, type: mode.id }))}
              className={`rounded-2xl border px-4 py-4 text-sm font-medium ${
                transferForm.type === mode.id
                  ? "border-cyan-300 bg-cyan-400/15 text-cyan-200"
                  : "border-white/10 bg-white/5 text-slate-300"
              }`}
            >
              {mode.label}
            </button>
          ))}
        </div>

        {transferForm.type === "transfer" ? (
          <div>
            <label className="mb-2 block text-sm text-slate-300">Destination user</label>
            <select
              value={transferForm.toUserId}
              onChange={(event) => setTransferForm((prev) => ({ ...prev, toUserId: event.target.value }))}
              className="w-full rounded-2xl border border-white/10 bg-white/5 px-4 py-4 text-white outline-none"
            >
              <option value="">Select a beneficiary</option>
              {users
                .filter((user) => user.id !== selectedUser?.id)
                .map((user) => (
                  <option key={user.id} value={user.id}>{user.full_name} ({user.id})</option>
                ))}
            </select>
          </div>
        ) : null}

        <FormField
          label="Amount"
          placeholder="0.00"
          value={transferForm.amount}
          onChange={(value) => setTransferForm((prev) => ({ ...prev, amount: value }))}
          type="number"
        />

        <div>
          <label className="mb-2 block text-sm text-slate-300">Reference</label>
          <textarea
            value={transferForm.reference}
            onChange={(event) => setTransferForm((prev) => ({ ...prev, reference: event.target.value }))}
            className="h-28 w-full rounded-2xl border border-white/10 bg-white/5 px-4 py-4 text-white outline-none placeholder:text-slate-500"
            placeholder="Payment reference"
          />
        </div>

        <button className="w-full rounded-2xl bg-gradient-to-r from-cyan-400 to-blue-600 px-5 py-4 font-medium text-slate-950 shadow-lg shadow-cyan-500/25">
          Confirm Transaction
        </button>
      </form>
    </Shell>
  );
}

function ReportScreen({ selectedUser, balance, transactions, activities, moneyInThisMonth, spendingThisMonth, safeToSpend }) {
  const weeklyBars = buildWeeklyBars(transactions);

  return (
    <Shell
      title="Statements & reports"
      subtitle="A customer-friendly reporting page for viewing balance trends, transactions and activity."
      aside={
        <div className="space-y-5">
          <div className="rounded-[28px] border border-white/10 bg-white/5 p-6">
            <p className="text-sm text-slate-400">Customer</p>
            <h3 className="mt-2 text-3xl font-semibold">{selectedUser?.full_name || "No user selected"}</h3>
            <p className="mt-3 text-sm text-slate-300">Live report snapshot from your local proof of concept.</p>
          </div>
          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-1">
            <MetricCard title="Money In" value={currency.format(moneyInThisMonth)} tone="text-emerald-300" />
            <MetricCard title="Money Out" value={currency.format(spendingThisMonth)} tone="text-white" />
          </div>
        </div>
      }
    >
      <div className="grid gap-5 md:grid-cols-2">
        <div className="rounded-[28px] border border-white/10 bg-white/5 p-5">
          <p className="text-sm text-slate-400">Available balance</p>
          <h3 className="mt-2 text-xl font-semibold">{currency.format(balance)}</h3>
        </div>
        <div className="rounded-[28px] border border-white/10 bg-white/5 p-5">
          <p className="text-sm text-slate-400">Safe to spend</p>
          <h3 className="mt-2 text-xl font-semibold">{currency.format(safeToSpend)}</h3>
        </div>
      </div>

      <div className="mt-5 rounded-[28px] border border-white/10 bg-white/5 p-6">
        <div className="mb-5 flex items-center justify-between">
          <h3 className="text-lg font-semibold">Weekly transaction pattern</h3>
          <span className="text-sm text-slate-400">Last 7 groups</span>
        </div>
        <div className="flex items-end justify-between gap-3">
          {weeklyBars.map((bar, idx) => (
            <div key={`${bar.label}-${idx}`} className="flex flex-1 flex-col items-center gap-3">
              <div className="w-full rounded-t-2xl bg-gradient-to-t from-cyan-500 to-blue-500" style={{ height: `${bar.height}px`, minHeight: "16px" }} />
              <span className="text-xs text-slate-500">{bar.label}</span>
            </div>
          ))}
        </div>
      </div>

      <div className="mt-5 grid gap-4 sm:grid-cols-2">
        <MetricCard title="Transactions" value={String(transactions.length)} tone="text-white" />
        <MetricCard title="Activity Events" value={String(activities.length)} tone="text-white" />
      </div>

      <div className="mt-5 grid gap-4 sm:grid-cols-2">
        <button className="rounded-2xl border border-white/10 bg-white/5 px-5 py-4 text-left font-medium text-white">Download PDF Statement</button>
        <button className="rounded-2xl border border-white/10 bg-white/5 px-5 py-4 text-left font-medium text-white">Export CSV Report</button>
      </div>
    </Shell>
  );
}

function FormField({ label, placeholder, type = "text", value, onChange, required = false, minLength }) {
  return (
    <div>
      <label className="mb-2 block text-sm text-slate-300">{label}</label>
      <input
        type={type}
        value={value}
        onChange={(event) => onChange?.(event.target.value)}
        className="w-full rounded-2xl border border-white/10 bg-white/5 px-4 py-4 text-white outline-none placeholder:text-slate-500"
        placeholder={placeholder}
        required={required}
        minLength={minLength}
      />
    </div>
  );
}

function MetricCard({ title, value, tone }) {
  return (
    <div className="rounded-[24px] border border-white/10 bg-white/5 p-5">
      <p className="text-sm text-slate-400">{title}</p>
      <h4 className={`mt-2 text-3xl font-semibold ${tone}`}>{value}</h4>
    </div>
  );
}

function niceType(type) {
  return String(type || "")
    .toLowerCase()
    .split("_")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function formatDate(value) {
  if (!value) return "Recent";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Recent";
  return date.toLocaleString("en-GB", {
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function buildWeeklyBars(transactions) {
  const dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const now = new Date();
  // Build buckets for the last 7 calendar days (oldest first).
  const buckets = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(now);
    d.setDate(d.getDate() - i);
    buckets.push({ label: dayLabels[d.getDay()], key: d.toISOString().slice(0, 10), total: 0 });
  }
  for (const tx of transactions) {
    const key = new Date(tx.createdAt).toISOString().slice(0, 10);
    const bucket = buckets.find((b) => b.key === key);
    if (bucket) bucket.total += Math.abs(Number(tx.amount || 0));
  }
  const max = Math.max(...buckets.map((b) => b.total), 1);
  const hasData = buckets.some((b) => b.total > 0);
  return buckets.map((b, index) => ({
    label: b.label,
    height: hasData ? Math.max((b.total / max) * 180, 16) : 20 + index * 8,
  }));
}
