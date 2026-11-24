import {jsPDF} from 'jspdf';
import {reportFields,bytes} from './domain.js';
const clean=value=>String(value??'').replace(/\r\n?/g,'\n').replace(/[^\S\n]+/g,' ').replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g,'');
const time=value=>value?new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'}).format(new Date(value)):'—';
export function buildReportPdf(report,attachments,fontBase64){
 if(report.status!=='approved')throw Error('승인 완료된 보고서만 PDF로 저장할 수 있습니다.');
 const doc=new jsPDF({unit:'mm',format:'a4',compress:true,putOnlyUsedFonts:true});
 doc.addFileToVFS('NanumGothic-Regular.ttf',fontBase64);doc.addFont('NanumGothic-Regular.ttf','Nanum','normal');doc.setFont('Nanum','normal');
 const left=19,width=172,bottom=274;let y=20;
 function page(){doc.addPage();y=21;doc.setFontSize(8);doc.setTextColor(110,135,119);doc.text('DAYLOG · 일일 업무보고 (계속)',left,y);y+=12;}
 function space(n){if(y+n>bottom)page();}
 function lines(text,size=10.5,color=[67,89,75],lineHeight=5.9){doc.setFontSize(size);doc.setTextColor(...color);const wrapped=doc.splitTextToSize(clean(text)||'기재 내용 없음',width);for(const line of wrapped){space(lineHeight);doc.setFontSize(size);doc.setTextColor(...color);doc.text(line,left,y);y+=lineHeight;}}
 doc.setProperties({title:clean(report.title),author:clean(report.author_name),subject:'승인 완료된 일일 업무보고',creator:'DAYLOG'});
 doc.setFontSize(9);doc.setTextColor(20,107,87);doc.text('DAYLOG  /  DAILY WORK REPORT',left,y);y+=11;
 lines(report.title,19,[26,61,43],9);y+=3;doc.setDrawColor(20,107,87);doc.setLineWidth(.6);doc.line(left,y,left+width,y);y+=9;
 lines(`보고일: ${report.report_date}    작성자: ${report.author_name}`,10,[90,111,97],6.5);
 lines(`소속: ${report.department||'미등록'}    상태: 승인 완료`,10,[90,111,97],6.5);
 lines(`제출: ${time(report.submitted_at)}    승인: ${time(report.reviewed_at)}`,9,[110,130,115],6);y+=4;
 function section(title,body){space(22);doc.setFontSize(11);doc.setTextColor(20,107,87);doc.text(title,left,y);y+=7;lines(body);y+=3;space(3);doc.setDrawColor(226,234,227);doc.setLineWidth(.2);doc.line(left,y,left+width,y);y+=7;}
 for(const [field,label]of reportFields)section(label,report[field]);
 section('첨부파일 목록',attachments.length?attachments.map((f,i)=>`${i+1}. ${f.file_name} (${bytes(f.size_bytes)})`).join('\n'):'첨부파일 없음');
 section('관리자 검토 의견',report.review_note||'승인 완료');
 space(20);lines('첨부파일 본문은 포함되지 않습니다. 앱에서 별도로 다운로드할 수 있습니다.',8,[135,151,139],5);lines(`문서 ID: ${report.id}`,8,[135,151,139],5);
 const total=doc.getNumberOfPages();for(let i=1;i<=total;i++){doc.setPage(i);doc.setFont('Nanum','normal');doc.setFontSize(8);doc.setTextColor(145,159,148);doc.text(`DAYLOG · 승인 업무보고`,left,286);doc.text(`${i} / ${total}`,191,286,{align:'right'});}
 return doc;
}
