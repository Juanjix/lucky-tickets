import { siteConfig } from "@/config/site";

export default function Home() {
  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-3 bg-zinc-50 px-6 text-center dark:bg-black">
      <h1 className="text-3xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
        {siteConfig.name}
      </h1>
      <p className="max-w-md text-lg text-zinc-600 dark:text-zinc-400">
        {siteConfig.tagline}
      </p>
    </main>
  );
}
