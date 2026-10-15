import Link from 'next/link';
import { ArrowRight, AppWindow, FolderOpen, HardDrive, BookOpen, LifeBuoy, FlaskConical } from 'lucide-react';
const guides = [
  { icon: AppWindow, title: '迁移应用', text: '了解应用如何移到外置盘，以及迁移后的启动与更新。', href: '/docs/core' },
  { icon: FolderOpen, title: '迁移数据', text: '找到占用空间的数据目录，选择适合的迁移方式。', href: '/docs/datamigrae/operation' },
  { icon: HardDrive, title: '准备外置存储', text: '了解磁盘格式、连接方式和日常使用的注意事项。', href: '/docs/storage-guide' },
  { icon: BookOpen, title: '看懂状态徽章', text: '认识应用列表中的标记，知道下一步可以做什么。', href: '/docs/badges' },
  { icon: LifeBuoy, title: '解决使用问题', text: '从遇到的现象出发，找到排查与恢复的方法。', href: '/docs/faq' },
  { icon: FlaskConical, title: '阅读实验记录', text: '查看迁移方案的测试过程、观察结果与适用范围。', href: '/docs/research/sandbox-symlink' },
];
export default function HomePage() {
  return <main className="home-main">
    <section className="home-hero">
      <div className="hero-copy"><p className="eyebrow">APPPORTS / 使用文档</p><h1>让应用与数据，<br />在外置盘上安家。</h1>
        <div className="hero-actions"><Link className="primary-link" href="/docs/faststart">开始使用 <ArrowRight size={17} /></Link><Link className="secondary-link" href="/docs/AppPorts">了解 AppPorts <ArrowRight size={16} /></Link></div>
      </div>
      <div className="storage-visual" aria-hidden="true"><div className="storage-grid" /><div className="source-stack"><span /><span /><div><AppWindow size={31} /><FolderOpen size={30} /></div><p>应用与数据</p></div><div className="transfer-line"><i /><i /><i /><ArrowRight size={19} /></div><div className="drive"><div className="drive-face"><img src="/logo.png" alt="" width="46" height="46" /><span className="drive-light" /></div><span className="drive-port" /><p>外置存储</p></div></div>
    </section>
    <section className="guides-section"><div className="section-heading"><div><p className="eyebrow">从这里开始</p><h2>找到你需要的指南</h2></div><p>按你现在想做的事，选择一个入口。</p></div><div className="guide-grid">{guides.map(({ icon: Icon, title, text, href }) => <Link key={href} href={href} className="guide-card"><Icon className="guide-icon" size={23} /><h3>{title}<ArrowRight size={17} /></h3><p>{text}</p></Link>)}</div></section>
    <Link href="/docs/macos-27" className="upgrade-banner"><span className="upgrade-icon"><LifeBuoy size={23} /></span><div><h2>准备升级 macOS 27？</h2><p>先了解旧迁移方式的影响，以及需要完成的检查。</p></div><ArrowRight size={20} /></Link>
    <footer className="site-footer"><span>© {new Date().getFullYear()} AppPorts</span><nav aria-label="站点信息"><Link href="/docs/sponsor">赞助</Link><Link href="/docs/contributing">参与贡献</Link><Link href="/docs/archive/overview">历史功能归档</Link><Link href="/docs/privacy">隐私政策</Link><Link href="/docs/licenses">开源许可</Link></nav></footer>
  </main>;
}
