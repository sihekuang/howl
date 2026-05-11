import Foundation

/// Curated vocabulary packs the user can apply via the Dictionary tab.
/// Each pack is a list of distinctive proper nouns / acronyms / domain
/// terms that Whisper tends to mis-transcribe — selecting a pack unions
/// these into UserSettings.customDict (deduped). The fuzzy matcher in
/// core/internal/dict then snaps near-misses back to the canonical form.
///
/// Common English words are deliberately omitted; the LLM cleanup pass
/// handles grammar and prose. Pack entries are the kind of thing where
/// the spelling matters and Whisper guesses wrong.
enum OccupationPacks {
    /// Pack metadata for the picker UI. `name` is the display label;
    /// `terms` is the word list applied on selection.
    struct Pack: Identifiable, Hashable {
        let id: String       // stable key, also used as the picker tag
        let name: String     // user-visible label
        let terms: [String]
    }

    /// Ordered for a sensible picker presentation. The "General Tech"
    /// pack is broad enough to be useful for most engineering roles;
    /// the others narrow to specific domains.
    static let all: [Pack] = [
        Pack(
            id: "software-engineer",
            name: "Software Engineer",
            terms: [
                "API", "OAuth", "JWT", "GraphQL", "REST", "gRPC", "WebSocket", "WebRTC",
                "TypeScript", "JavaScript", "Python", "Golang", "Rust", "Kotlin", "Swift",
                "Kubernetes", "Docker", "Terraform", "Ansible", "Helm",
                "PostgreSQL", "MongoDB", "Redis", "Cassandra", "DynamoDB",
                "AWS", "GCP", "Azure", "Lambda", "EC2", "S3",
                "GitHub", "GitLab", "Bitbucket", "Jenkins", "CircleCI",
                "Jira", "Linear", "Notion",
                "MCP", "LLM", "RAG", "SDK", "CLI", "IDE",
                "TLS", "DNS", "CDN", "VPN", "OAuth2", "OIDC",
            ]
        ),
        Pack(
            id: "ai-ml",
            name: "AI / ML Engineer",
            terms: [
                "PyTorch", "TensorFlow", "JAX", "ONNX", "CUDA", "TensorRT",
                "HuggingFace", "Transformers", "Diffusers", "LangChain", "LlamaIndex",
                "GPT", "Claude", "Gemini", "Llama", "Mistral", "Qwen",
                "RLHF", "SFT", "LoRA", "QLoRA", "DPO", "PPO",
                "embedding", "tokenizer", "logits", "softmax", "attention",
                "transformer", "encoder", "decoder",
                "MCP", "RAG", "MoE", "MMLU", "GSM8K", "HellaSwag",
                "Anthropic", "OpenAI", "DeepMind", "Meta AI",
            ]
        ),
        Pack(
            id: "designer",
            name: "Designer",
            terms: [
                "Figma", "Sketch", "Framer", "Adobe", "Photoshop", "Illustrator",
                "InDesign", "After Effects", "Premiere", "Procreate",
                "wireframe", "mockup", "prototype",
                "kerning", "leading", "tracking", "ligature",
                "CMYK", "RGB", "sRGB", "HSL", "Pantone",
                "WCAG", "ARIA", "a11y",
                "Material", "iOS HIG", "macOS HIG",
            ]
        ),
        Pack(
            id: "medical",
            name: "Medical / Clinical",
            terms: [
                "tachycardia", "bradycardia", "arrhythmia", "fibrillation",
                "hypertension", "hypotension", "hyperglycemia", "hypoglycemia",
                "epinephrine", "norepinephrine", "ibuprofen", "acetaminophen",
                "metformin", "atorvastatin", "lisinopril",
                "myocardial", "ischemia", "infarction", "edema", "embolism",
                "MRI", "CT", "ECG", "EKG", "EEG", "BMI", "ICU", "ER",
                "anaphylaxis", "sepsis", "diabetes", "asthma", "COPD",
                "stat", "PRN", "IV", "IM", "NPO",
            ]
        ),
        Pack(
            id: "legal",
            name: "Legal",
            terms: [
                "voir dire", "habeas corpus", "amicus curiae", "stare decisis",
                "res judicata", "prima facie", "mens rea", "actus reus",
                "indemnification", "tort", "estoppel", "subrogation",
                "deposition", "discovery", "interrogatory", "subpoena",
                "plaintiff", "defendant", "appellant", "respondent",
                "GDPR", "CCPA", "HIPAA", "DMCA",
                "LLC", "LLP", "S-Corp", "C-Corp",
                "NDA", "IP", "EULA", "TOS",
            ]
        ),
        Pack(
            id: "finance",
            name: "Finance / Trading",
            terms: [
                "EBITDA", "ROI", "ROE", "ROIC", "IRR", "NPV", "DCF",
                "P/E", "P/B", "EPS", "FCF", "ARPU", "LTV", "CAC", "MRR", "ARR",
                "S&P", "NASDAQ", "NYSE", "Dow Jones", "Russell",
                "FOMC", "FOMO", "QE", "QT", "CPI", "PCE",
                "ETF", "REIT", "ADR", "OTC", "IPO", "SPAC",
                "Treasuries", "junk bonds", "yield curve",
                "Bitcoin", "Ethereum", "Solana", "DeFi", "stablecoin",
            ]
        ),
        Pack(
            id: "academic",
            name: "Academic / Research",
            terms: [
                "arXiv", "BibTeX", "LaTeX", "Overleaf",
                "p-value", "ANOVA", "regression", "heteroskedasticity",
                "ICLR", "NeurIPS", "ICML", "CVPR", "ACL", "EMNLP",
                "DOI", "ORCID", "PubMed", "JSTOR", "Scopus",
                "PhD", "postdoc", "tenure-track", "sabbatical",
                "IRB", "RFP", "NSF", "NIH",
            ]
        ),
    ]
}
